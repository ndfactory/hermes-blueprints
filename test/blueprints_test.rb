# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../lib/hermes_blueprints"

class HermesBlueprintsTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("hermes-blueprints-test-")
    @log = File.join(@tmp, "hermes.jsonl")
    ENV["FAKE_HERMES_LOG"] = @log
    @fake_hermes = File.join(@tmp, "hermes")
    File.write(@fake_hermes, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      args = ARGV
      File.open(ENV.fetch("FAKE_HERMES_LOG"), "a") { |file| file.puts(JSON.generate(args)) }
      if args == ["--version"]
        puts ENV.fetch("FAKE_HERMES_VERSION", "Hermes Agent v0.22.5 (test)")
      elsif args[0, 3] == ["kanban", "boards", "create"]
        if ENV["FAKE_HERMES_FAIL_BOARD"] == "1"
          warn "Board slug already exists"
          exit 1
        end
        puts "created board"
      elsif args[0, 2] == ["profile", "show"] && ENV["FAKE_HERMES_MISSING_PROFILE"] == args[2]
        warn "Profile not found"
        exit 1
      elsif args.include?("create") && args.include?("--json")
        task_creates = File.readlines(ENV.fetch("FAKE_HERMES_LOG")).map { |line| JSON.parse(line) }
                          .count { |call| call.include?("create") && call.include?("--json") }
        if ENV["FAKE_HERMES_FAIL_TASK"] == (task_creates - 1).to_s
          warn "simulated task failure"
          exit 1
        end
        puts JSON.generate("task" => { "id" => "task-#{task_creates}" })
      else
        puts "ok"
      end
    RUBY
    FileUtils.chmod(0o755, @fake_hermes)
    @env = { "FAKE_HERMES_LOG" => @log }
  end

  def teardown
    ENV.delete("FAKE_HERMES_LOG")
    ENV.delete("FAKE_HERMES_FAIL_BOARD")
    ENV.delete("FAKE_HERMES_VERSION")
    ENV.delete("FAKE_HERMES_FAIL_TASK")
    ENV.delete("FAKE_HERMES_MISSING_PROFILE")
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_catalog_lists_and_validates_both_starter_blueprints
    blueprints = HermesBlueprints::Catalog.new.validate!

    assert_equal %w[research software-development], blueprints.map { |item| item.fetch("id") }
    assert blueprints.all? { |item| File.file?(File.join(item.fetch("_directory"), "templates", "README.md")) }
    assert blueprints.all? { |item| File.file?(File.join(item.fetch("_directory"), "templates", "AGENTS.md")) }
  end

  def test_renderer_rejects_unknown_and_missing_placeholders
    assert_raises(HermesBlueprints::Error) do
      HermesBlueprints.render("{{unknown}}", {})
    end
    assert_raises(HermesBlueprints::Error) do
      HermesBlueprints.render("{{idea_name}}", {})
    end
  end

  def test_validator_rejects_unknown_template_placeholders
    copied_catalog = File.join(@tmp, "catalog")
    FileUtils.cp_r(HermesBlueprints::BLUEPRINTS_DIR, copied_catalog)
    path = File.join(copied_catalog, "research", "templates", "README.md")
    File.open(path, "a") { |file| file.puts "{{unsupported_value}}" }

    error = assert_raises(HermesBlueprints::Error) do
      HermesBlueprints::Catalog.new(copied_catalog).validate!
    end
    assert_includes error.message, "Unknown template placeholder"
  end

  def test_wizard_generates_project_and_provisions_a_requirements_driven_triage_goal
    destination = File.join(@tmp, "ideas", "literature-review")
    Dir.mkdir(File.dirname(destination))
    output = StringIO.new
    errors = StringIO.new

    HermesBlueprints::Generator.new(hermes: @fake_hermes, output: output, error_output: errors)
                          .generate(blueprint: "research", name: "Literature Review", description: "Review the evidence.", requirements: "Compare studies from 2020 onward and cite primary sources.", output_path: destination)

    assert_equal "Literature Review", File.read(File.join(destination, "README.md")).lines.first.delete_prefix("# ").strip
    assert_includes File.read(File.join(destination, "AGENTS.md")), "Review the evidence."
    assert_includes File.read(File.join(destination, "project-plan.md")), "Compare studies from 2020 onward"
    skill = File.read(File.join(destination, ".agents/skills/research-project/SKILL.md"))
    assert skill.start_with?("---\nname: research-project\n")
    refute_includes skill, "{{"
    calls = File.readlines(@log).map { |line| JSON.parse(line) }
    board = calls.find { |call| call[0, 3] == ["kanban", "boards", "create"] }
    assert_equal ["kanban", "boards", "create", "literature-review", "--name", "Literature Review", "--description", "Review the evidence."], board
    assert calls.none? { |call| call.include?("--switch") }
    task_creates = calls.select { |call| call.include?("create") && call.include?("--json") }
    assert_equal 1, task_creates.length
    assert task_creates.all? { |call| call.include?("--board") && call.include?("literature-review") && call.include?("--idempotency-key") }
    task = task_creates.first
    assert_includes task, "--triage"
    assert_includes task, "--assignee"
    assert_includes task, "hbplanner"
    assert_includes task, "--workspace"
    assert_includes task.join(" "), destination
    assert_includes task.join(" "), "Compare studies from 2020 onward"
    assert_empty calls.select { |call| call.include?("link") }
    assert_includes output.string, "triage goal task ID: task-1"
    assert_empty errors.string
  end

  def test_existing_output_folder_is_never_overwritten
    destination = File.join(@tmp, "existing")
    Dir.mkdir(destination)
    marker = File.join(destination, "keep.txt")
    File.write(marker, "keep")

    error = assert_raises(HermesBlueprints::Error) do
      HermesBlueprints::Generator.new(hermes: @fake_hermes).generate(
        blueprint: "research", name: "Existing", description: "test", requirements: "Test requirements.", output_path: destination
      )
    end

    assert_includes error.message, "already exists"
    assert_equal "keep", File.read(marker)
    refute File.exist?(@log)
  end

  def test_board_slug_collision_does_not_create_project_files
    ENV["FAKE_HERMES_FAIL_BOARD"] = "1"
    destination = File.join(@tmp, "idea")
    errors = StringIO.new

    error = assert_raises(HermesBlueprints::Error) do
      HermesBlueprints::Generator.new(hermes: @fake_hermes, error_output: errors).generate(
        blueprint: "research", name: "Idea", description: "test", requirements: "Test requirements.", output_path: destination
      )
    end

    assert_includes error.message, "already exists"
    refute File.exist?(destination)
  ensure
    ENV.delete("FAKE_HERMES_FAIL_BOARD")
  end

  def test_version_mismatch_fails_before_creating_board
    ENV["FAKE_HERMES_VERSION"] = "Hermes Agent v0.23.0"
    destination = File.join(@tmp, "idea")

    error = assert_raises(HermesBlueprints::Error) do
      HermesBlueprints::Generator.new(hermes: @fake_hermes).generate(
        blueprint: "research", name: "Idea", description: "test", requirements: "Test requirements.", output_path: destination
      )
    end

    assert_includes error.message, "v0.22.5 is required"
    calls = File.readlines(@log).map { |line| JSON.parse(line) }
    refute calls.any? { |call| call.include?("boards") && call.include?("create") }
    refute File.exist?(destination)
  ensure
    ENV.delete("FAKE_HERMES_VERSION")
  end

  def test_missing_hermes_executable_has_an_actionable_error
    error = assert_raises(HermesBlueprints::Error) do
      HermesBlueprints::Generator.new(hermes: File.join(@tmp, "missing-hermes")).generate(
        blueprint: "research", name: "Idea", description: "test", requirements: "Test requirements.", output_path: File.join(@tmp, "idea")
      )
    end
    assert_includes error.message, "was not found in PATH"
  end

  def test_missing_profiles_are_reported_before_board_creation
    ENV["FAKE_HERMES_MISSING_PROFILE"] = "hbresearcher"
    destination = File.join(@tmp, "idea")
    error = assert_raises(HermesBlueprints::Error) do
      HermesBlueprints::Generator.new(hermes: @fake_hermes).generate(
        blueprint: "research", name: "Idea", description: "test", requirements: "Detailed requirements.", output_path: destination
      )
    end

    assert_includes error.message, "Missing Hermes profiles: hbresearcher"
    assert_includes error.message, "setup-profiles"
    refute File.exist?(destination)
    calls = File.readlines(@log).map { |line| JSON.parse(line) }
    refute calls.any? { |call| call.include?("boards") && call.include?("create") }
  ensure
    ENV.delete("FAKE_HERMES_MISSING_PROFILE")
  end

  def test_setup_profiles_creates_roles_and_enables_planner_kanban
    output = StringIO.new
    HermesBlueprints::Generator.new(hermes: @fake_hermes, output: output).setup_profiles(blueprint: "research")

    calls = File.readlines(@log).map { |line| JSON.parse(line) }
    assert_includes calls, ["profile", "create", "hbplanner", "--description", "Project orchestrator. Clarifies scope, decomposes goals into dependency-aware tasks, delegates to specialists, integrates their work, and reports blockers and completion."]
    assert_includes calls, ["-p", "hbplanner", "tools", "enable", "kanban"]
    assert_includes output.string, "hermes gateway start"
  end

  def test_mid_provisioning_failure_reports_recovery_details_and_keeps_created_files
    ENV["FAKE_HERMES_FAIL_TASK"] = "0"
    destination = File.join(@tmp, "partial")
    errors = StringIO.new

    error = assert_raises(HermesBlueprints::Error) do
      HermesBlueprints::Generator.new(hermes: @fake_hermes, error_output: errors).generate(
        blueprint: "research", name: "Partial Idea", description: "test", requirements: "Test requirements.", output_path: destination
      )
    end

    assert_includes error.message, "simulated task failure"
    assert File.file?(File.join(destination, "README.md"))
    assert_includes errors.string, "board 'partial-idea'"
    assert_includes errors.string, destination
    assert_includes errors.string, "Generated project:"
  ensure
    ENV.delete("FAKE_HERMES_FAIL_TASK")
  end

  def test_cli_lists_blueprints_and_prints_help
    list = StringIO.new
    assert_equal 0, HermesBlueprints::CLI.new(["list"], output: list).run
    assert_includes list.string, "research\tResearch"
    assert_includes list.string, "software-development\tSoftware Development"

    help = StringIO.new
    assert_equal 0, HermesBlueprints::CLI.new(["--help"], output: help).run
    assert_includes help.string, "hermes-blueprint new"
    assert_includes help.string, "setup-profiles"
  end

  def test_interactive_cli_walks_through_blueprint_selection_and_confirmation
    destination = File.join(@tmp, "from-wizard")
    input = StringIO.new("1\nWizard Idea\nA prompted idea.\nFirst requirement.\nSecond requirement.\n.\n#{destination}\ny\n")
    output = StringIO.new
    errors = StringIO.new

    result = HermesBlueprints::CLI.new(["new"], input: input, output: output, error_output: errors, hermes: @fake_hermes).run

    assert_equal 0, result
    assert File.file?(File.join(destination, "README.md"))
    assert_includes output.string, "Choose a blueprint"
    assert_includes output.string, "Created Hermes Kanban board 'wizard-idea'"
    assert_empty errors.string
  end
end
