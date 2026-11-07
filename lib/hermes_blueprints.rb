# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

module HermesBlueprints
  ROOT = File.expand_path("..", __dir__)
  BLUEPRINTS_DIR = File.join(ROOT, "blueprints")
  HERMES_VERSION = "0.22.5"
  PLACEHOLDERS = %w[idea_name idea_slug idea_description blueprint_name skill_id].freeze

  class Error < StandardError; end

  class Catalog
    def initialize(directory = BLUEPRINTS_DIR)
      @directory = directory
    end

    def all
      Dir.glob(File.join(@directory, "*", "blueprint.json")).sort.map do |manifest_path|
        load_blueprint(File.dirname(manifest_path))
      end
    end

    def find(id)
      blueprint = all.find { |item| item.fetch("id") == id }
      raise Error, "Unknown blueprint '#{id}'. Run `hermes-blueprint list` to see available blueprints." unless blueprint

      blueprint
    end

    def validate!
      blueprints = all
      raise Error, "No blueprints found in #{@directory}." if blueprints.empty?

      ids = blueprints.map { |item| item.fetch("id") }
      raise Error, "Blueprint IDs must be unique." unless ids.uniq.length == ids.length

      blueprints.each { |blueprint| validate_blueprint!(blueprint) }
      blueprints
    end

    private

    def load_blueprint(directory)
      manifest_path = File.join(directory, "blueprint.json")
      data = JSON.parse(File.read(manifest_path))
      data["_directory"] = directory
      data
    rescue JSON::ParserError => e
      raise Error, "Invalid JSON in #{manifest_path}: #{e.message}"
    rescue Errno::ENOENT
      raise Error, "Missing blueprint manifest: #{manifest_path}"
    end

    def validate_blueprint!(blueprint)
      %w[id name description skill_id orchestrator_profile profiles workflow_guidance].each do |key|
        raise Error, "#{blueprint["_directory"]}: missing required field '#{key}'." unless blueprint.key?(key)
      end
      %w[id name description skill_id].each do |key|
        unless blueprint[key].is_a?(String) && !blueprint[key].strip.empty?
          raise Error, "#{blueprint["_directory"]}: '#{key}' must be a non-empty string."
        end
      end
      unless blueprint["id"].match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
        raise Error, "Invalid blueprint id '#{blueprint["id"]}'. Use lowercase letters, numbers, and hyphens."
      end
      unless blueprint["skill_id"].match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
        raise Error, "Invalid skill_id in blueprint '#{blueprint["id"]}'."
      end
      unless blueprint["profiles"].is_a?(Array) && !blueprint["profiles"].empty?
        raise Error, "Blueprint '#{blueprint["id"]}' must define at least one profile."
      end
      profile_ids = blueprint["profiles"].map do |profile|
        %w[id description].each do |key|
          raise Error, "Profile in '#{blueprint["id"]}' is missing '#{key}'." unless profile[key].is_a?(String) && !profile[key].strip.empty?
        end
        raise Error, "Invalid profile id '#{profile["id"]}'. Use lowercase letters and numbers only." unless profile["id"].match?(/\A[a-z0-9]+\z/)
        profile.fetch("id")
      end
      raise Error, "Profile IDs in '#{blueprint["id"]}' must be unique." unless profile_ids.uniq.length == profile_ids.length
      unless profile_ids.include?(blueprint["orchestrator_profile"])
        raise Error, "orchestrator_profile in '#{blueprint["id"]}' must name one of its profiles."
      end
      unless blueprint["workflow_guidance"].is_a?(Array) && !blueprint["workflow_guidance"].empty? && blueprint["workflow_guidance"].all? { |step| step.is_a?(String) && !step.strip.empty? }
        raise Error, "Blueprint '#{blueprint["id"]}' must define non-empty workflow_guidance strings."
      end
      blueprint["profiles"].each { |profile| HermesBlueprints.render(profile.fetch("description"), validation_values(blueprint)) }
      blueprint["workflow_guidance"].each { |step| HermesBlueprints.render(step, validation_values(blueprint)) }

      templates_dir = File.join(blueprint.fetch("_directory"), "templates")
      files = Dir.glob(File.join(templates_dir, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      raise Error, "Blueprint '#{blueprint["id"]}' has no template files." if files.empty?

      required_templates = [
        "README.md",
        "AGENTS.md",
        File.join(".agents", "skills", "{{skill_id}}", "SKILL.md")
      ]
      required_templates.each do |relative|
        raise Error, "Blueprint '#{blueprint["id"]}' is missing templates/#{relative}." unless File.file?(File.join(templates_dir, relative))
      end

      files.each do |path|
        HermesBlueprints.render(File.read(path), validation_values(blueprint))
        if path.end_with?("SKILL.md")
          content = File.read(path)
          raise Error, "#{path} must start with Hermes YAML frontmatter (---)." unless content.start_with?("---\n")
          raise Error, "#{path} must include a Skill Procedure section." unless content.include?("## Procedure")
        end
      end
      true
    end

    def validation_values(blueprint)
      PLACEHOLDERS.to_h { |key| [key, "validation-#{key}"] }.merge("blueprint_name" => blueprint.fetch("name"))
    end
  end

  class Generator
    def initialize(catalog: Catalog.new, hermes: "hermes", output: $stdout, error_output: $stderr)
      @catalog = catalog
      @hermes = hermes
      @output = output
      @error_output = error_output
    end

    def generate(blueprint:, name:, description:, requirements:, output_path:)
      @catalog.validate!
      item = @catalog.find(blueprint)
      values = values_for(item, name, description)
      destination = File.expand_path(output_path)
      values["output_path"] = destination
      requirements = requirements.to_s.strip
      raise Error, "Project requirements cannot be empty." if requirements.empty?
      values["project_requirements"] = requirements
      raise Error, "Output path already exists: #{destination}" if File.exist?(destination)
      raise Error, "Parent directory does not exist: #{File.dirname(destination)}" unless Dir.exist?(File.dirname(destination))
      raise Error, "Output path must be a directory path, not a file." if destination.end_with?("/") && File.file?(destination)

      verify_hermes!
      verify_profiles!(item)
      stage = stage_project(item, destination, values)
      board_slug = values.fetch("idea_slug")
      create_board!(board_slug, name, description)
      File.rename(stage, destination)
      stage = nil

      @output.puts "Created project files at #{destination}"
      @output.puts "Created Hermes Kanban board '#{board_slug}' (it was not made active)."
      seed_goal!(item, board_slug, values)
      @output.puts "Blueprint '#{item.fetch("name")}' is ready."
      destination
    ensure
      FileUtils.remove_entry(stage) if stage && File.exist?(stage)
    end

    def setup_profiles(blueprint:)
      @catalog.validate!
      item = @catalog.find(blueprint)
      verify_hermes!
      item.fetch("profiles").each do |profile|
        begin
          run_hermes!("profile", "create", profile.fetch("id"), "--description", profile.fetch("description"))
          @output.puts "Created profile '#{profile.fetch("id")}'. Run `hermes -p #{profile.fetch("id")} setup` to configure its model and credentials."
        rescue Error => e
          if e.message.match?(/already exists|exists|duplicate/i)
            @output.puts "Profile '#{profile.fetch("id")}' already exists; kept its existing settings."
          else
            raise Error, "Could not create profile '#{profile.fetch("id")}': #{e.message}"
          end
        end
      end
      planner = item.fetch("orchestrator_profile")
      run_hermes!("-p", planner, "tools", "enable", "kanban")
      @output.puts "Enabled Kanban tools for '#{planner}'. Configure each listed profile with `hermes -p PROFILE setup`, then start the dispatcher with `hermes gateway start`."
    end

    def verify_profiles!(blueprint)
      missing = blueprint.fetch("profiles").filter_map do |profile|
        _stdout, _stderr, status = Open3.capture3(@hermes, "profile", "show", profile.fetch("id"))
        profile.fetch("id") unless status.success?
      rescue Errno::ENOENT
        raise Error, "Hermes Agent v#{HERMES_VERSION} executable was not found."
      end
      return if missing.empty?

      raise Error, "Missing Hermes profiles: #{missing.join(", ")}. Run `hermes-blueprint setup-profiles --blueprint #{blueprint.fetch("id")}`, then configure each with `hermes -p PROFILE setup` before creating the idea."
    end

    private

    def values_for(blueprint, name, description)
      name = name.to_s.strip
      raise Error, "Idea name cannot be empty." if name.empty?
      slug = name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      raise Error, "Idea name must include at least one letter or number." if slug.empty?

      {
        "idea_name" => name,
        "idea_slug" => slug,
        "idea_description" => description.to_s.strip.empty? ? name : description.to_s.strip,
        "blueprint_name" => blueprint.fetch("name"),
        "skill_id" => blueprint.fetch("skill_id")
      }
    end

    def verify_hermes!
      stdout, stderr, status = Open3.capture3(@hermes, "--version")
      raise Error, "Hermes Agent v#{HERMES_VERSION} is required, but '#{@hermes}' could not be run: #{stderr.strip}" unless status.success?

      version_text = "#{stdout}\n#{stderr}"
      match = version_text.match(/\bv(\d+\.\d+\.\d+)\b/) || version_text.match(/\b(\d+\.\d+\.\d+)\b/)
      unless match && match[1] == HERMES_VERSION
        found = match ? match[1] : "unknown"
        raise Error, "Hermes Agent v#{HERMES_VERSION} is required; found '#{found}'."
      end
    rescue Errno::ENOENT
      raise Error, "Hermes Agent v#{HERMES_VERSION} is required but '#{@hermes}' was not found in PATH."
    end

    def stage_project(blueprint, destination, values)
      templates_dir = File.join(blueprint.fetch("_directory"), "templates")
      stage = Dir.mktmpdir(".hermes-blueprint-", File.dirname(destination))
      Dir.glob(File.join(templates_dir, "**", "*"), File::FNM_DOTMATCH).sort.each do |source|
        relative = HermesBlueprints.render(source.delete_prefix("#{templates_dir}/"), values)
        next if relative == "." || relative == ".."

        target = File.join(stage, relative)
        if File.directory?(source)
          FileUtils.mkdir_p(target)
        elsif File.file?(source)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, HermesBlueprints.render(File.read(source), values))
          FileUtils.chmod(File.stat(source).mode & 0o777, target)
        end
      end
      File.write(File.join(stage, "project-plan.md"), "# #{values.fetch("idea_name")} — Project plan\n\n#{values.fetch("project_requirements")}\n")
      stage
    rescue StandardError
      FileUtils.remove_entry(stage) if stage && File.exist?(stage)
      raise
    end

    def create_board!(slug, name, description)
      run_hermes!("kanban", "boards", "create", slug, "--name", name, "--description", description)
    rescue Error => e
      if e.message.match?(/already exists|duplicate|slug.+taken/i)
        raise Error, "A Hermes Kanban board with slug '#{slug}' already exists. Choose a different idea name."
      end
      raise Error, "Could not create board '#{slug}': #{e.message}"
    end

    def seed_goal!(blueprint, board_slug, values)
      roles = blueprint.fetch("profiles").map do |profile|
        "- #{profile.fetch("id")}: #{HermesBlueprints.render(profile.fetch("description"), values)}"
      end.join("\n")
      guidance = blueprint.fetch("workflow_guidance").map do |step|
        "- #{HermesBlueprints.render(step, values)}"
      end.join("\n")
      body = <<~BODY
        ## Project goal
        #{values.fetch("idea_description")}

        ## Full requirements and plan
        #{values.fetch("project_requirements")}

        ## Project workspace
        Work in #{values.fetch("output_path")}. Read `AGENTS.md`, `README.md`, `idea-brief.md`, and the project-local skill before making changes. Keep the project plan and artifacts current.

        ## Workflow guidance
        #{guidance}

        ## Available specialist profiles
        #{roles}

        You are the project orchestrator. Decompose this goal into a dependency-aware graph of concrete, verifiable tasks. Assign each task to the best matching specialist profile. Create enough tasks to complete the full requirements, include independent review and verification, and preserve this parent as the overall goal. Do not mark the goal complete until all requirements and acceptance criteria are met. If blocked by missing information or an external dependency, state exactly what is needed and leave the work blocked rather than claiming success.
      BODY
      id = create_task!(board_slug, "#{values.fetch("idea_name")}: #{blueprint.fetch("name")} project goal", body, "#{blueprint.fetch("id")}:#{values.fetch("idea_slug")}:goal", blueprint.fetch("orchestrator_profile"), File.expand_path(values.fetch("output_path")))
      @output.puts "Created triage goal task ID: #{id}; Hermes will decompose it when the gateway dispatcher is running."
    rescue Error => e
      @error_output.puts "Provisioning stopped after creating board '#{board_slug}'."
      @error_output.puts "Generated project: #{values.fetch("output_path")}" if values["output_path"]
      @error_output.puts "Known task IDs: #{id}" if id
      raise Error, e.message
    end

    def create_task!(board_slug, title, body, idempotency_key, assignee, workspace)
      stdout, stderr, status = Open3.capture3(
        @hermes, "kanban", "--board", board_slug, "create", title,
        "--body", body, "--assignee", assignee, "--triage", "--workspace", "dir:#{workspace}",
        "--idempotency-key", idempotency_key, "--json"
      )
      unless status.success?
        raise Error, [stderr.strip, stdout.strip].reject(&:empty?).join("\n")
      end

      extract_id(stdout)
    end

    def extract_id(output)
      begin
        parsed = JSON.parse(output)
        id = find_id(parsed)
        return id.to_s if id
      rescue JSON::ParserError
        # Some CLI builds may return a human-readable creation line despite --json.
      end

      match = output.match(/(?:created\s+(?:task\s+)?|task\s+id[:# ]+)\s*([A-Za-z0-9_-]+)/i)
      raise Error, "Hermes created a task but did not return its ID in a recognized format: #{output.strip}" unless match

      match[1]
    end

    def find_id(value)
      case value
      when Hash
        direct = value["task_id"] || value["id"]
        return direct unless direct.nil? || direct.is_a?(Hash) || direct.is_a?(Array)
        value.each_value do |child|
          found = find_id(child)
          return found unless found.nil?
        end
      when Array
        value.each do |child|
          found = find_id(child)
          return found unless found.nil?
        end
      end
      nil
    end

    def run_hermes!(*args)
      stdout, stderr, status = Open3.capture3(@hermes, *args)
      return stdout.strip if status.success?

      detail = [stderr.strip, stdout.strip].reject(&:empty?).join("\n")
      raise Error, detail.empty? ? "Hermes command failed: #{args.join(" ")}" : detail
    end
  end

  def self.render(content, values)
    rendered = content.gsub(/\{\{\s*([a-z0-9_]+)\s*\}\}/) do
      key = Regexp.last_match(1)
      raise Error, "Unknown template placeholder '{{#{key}}}'." unless PLACEHOLDERS.include?(key)
      raise Error, "No value supplied for template placeholder '{{#{key}}}'." unless values.key?(key)

      values.fetch(key).to_s
    end
    if rendered.match?(/\{\{\s*[^{}]+\s*\}\}/)
      raise Error, "Unresolved template placeholder in content."
    end
    rendered
  end

  class CLI
    def initialize(argv, input: $stdin, output: $stdout, error_output: $stderr, catalog: Catalog.new, hermes: "hermes")
      @argv = argv.dup
      @input = input
      @output = output
      @error_output = error_output
      @catalog = catalog
      @hermes = hermes
    end

    def run
      command = @argv.shift
      case command
      when "list"
        list_blueprints
        0
      when "validate"
        blueprints = @catalog.validate!
        @output.puts "Validated #{blueprints.length} blueprint(s)."
        0
      when "setup-profiles"
        options = parse_options(@argv)
        blueprint = options["blueprint"] || prompt("Blueprint ID")
        Generator.new(catalog: @catalog, hermes: @hermes, output: @output, error_output: @error_output)
                 .setup_profiles(blueprint: blueprint)
        0
      when "new", nil
        create_project
      when "--help", "-h", "help"
        @output.puts help_text
        0
      else
        raise Error, "Unknown command '#{command}'.\n#{help_text}"
      end
    rescue Error => e
      @error_output.puts e.message
      1
    end

    private

    def list_blueprints
      @catalog.validate!.each do |blueprint|
        @output.puts "#{blueprint.fetch("id")}\t#{blueprint.fetch("name")} — #{blueprint.fetch("description")}"
      end
      0
    end

    def create_project
      options = parse_options(@argv)
      blueprints = @catalog.validate!
      blueprint = options["blueprint"] || prompt_blueprint(blueprints)
      blueprint = @catalog.find(blueprint)
      name = options["name"] || prompt("Idea name")
      description = options["description"] || prompt("One-sentence idea description", default: name)
      requirements = if options["requirements_file"]
                       begin
                         File.read(options["requirements_file"])
                       rescue SystemCallError => e
                         raise Error, "Could not read requirements file '#{options["requirements_file"]}': #{e.message}"
                       end
                     else
                       prompt_multiline_requirements
                     end
      output_path = options["output"] || prompt("Full output folder path")
      raise Error, "Output path cannot be empty." if output_path.to_s.strip.empty?

      @output.puts "\nBlueprint: #{blueprint.fetch("name")}"
      @output.puts "Idea: #{name}"
      @output.puts "Output: #{File.expand_path(output_path)}"
      @output.puts "Requirements: #{requirements.lines.count} line(s)"
      confirm = prompt("Create project and Hermes board? [y/N]", default: "n")
      raise Error, "Cancelled." unless confirm.downcase.start_with?("y")

      Generator.new(catalog: @catalog, hermes: @hermes, output: @output, error_output: @error_output)
               .generate(blueprint: blueprint.fetch("id"), name: name, description: description, requirements: requirements, output_path: output_path)
      0
    end

    def parse_options(args)
      options = {}
      until args.empty?
        flag = args.shift
        if %w[--blueprint --name --description --output --requirements-file].include?(flag)
          raise Error, "Missing value for #{flag}." if args.empty? || args.first.start_with?("--")
          options[flag.delete_prefix("--")] = args.shift
        elsif %w[-h --help].include?(flag)
          @output.puts help_text
          exit(0)
        else
          raise Error, "Unknown option '#{flag}'."
        end
      end
      options
    end

    def prompt_multiline_requirements
      @output.puts "Enter the overall project plan, requirements, constraints, and acceptance criteria. Finish with a line containing only a period (.)."
      lines = []
      loop do
        line = @input.gets
        raise Error, "Input ended before requirements were complete." unless line
        break if line.chomp == "."
        lines << line
      end
      content = lines.join.strip
      raise Error, "Project requirements cannot be empty." if content.empty?
      content
    end

    def prompt_blueprint(blueprints)
      @output.puts "Available blueprints:"
      blueprints.each_with_index { |item, index| @output.puts "  #{index + 1}. #{item.fetch("name")} (#{item.fetch("id")})" }
      loop do
        answer = prompt("Choose a blueprint by number or ID")
        selected = blueprints[answer.to_i - 1] if answer.match?(/\A\d+\z/)
        selected ||= blueprints.find { |item| item.fetch("id") == answer }
        return selected.fetch("id") if selected

        @output.puts "Please enter one of the listed numbers or IDs."
      end
    end

    def prompt(label, default: nil)
      suffix = default ? " [#{default}]" : ""
      @output.print "#{label}#{suffix}: "
      answer = @input.gets
      raise Error, "Input ended before the wizard finished." unless answer

      answer = answer.strip
      answer.empty? && default ? default : answer
    end

    def help_text
      <<~HELP
        Hermes Agent Blueprint catalog

        Usage:
          hermes-blueprint new [--blueprint ID] [--name NAME] [--description TEXT] [--requirements-file PATH] [--output PATH]
          hermes-blueprint setup-profiles --blueprint ID
          hermes-blueprint list
          hermes-blueprint validate
          hermes-blueprint --help
      HELP
    end
  end
end
