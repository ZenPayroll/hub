if defined?(Bundler) && defined?(URI)
  Object.send(:remove_const, :URI)
  $".reject! { |p| p =~ %r{(^|/)uri[/.]} }
end

require 'minitest/autorun'
require 'ghub'

# We're checking for `open` in our tests
ENV['BROWSER'] = 'open'

# Setup path with fake executables in case a test hits them
fakebin_dir = File.expand_path('../fakebin', __FILE__)
ENV['PATH'] = "#{fakebin_dir}:#{ENV['PATH']}"

# Use an isolated config file in testing
tmp_dir = ENV['TMPDIR'] || ENV['TEMP'] || '/tmp'
ENV['HUB_CONFIG'] = File.join(tmp_dir, 'ghub-test-config')

# Disable `abort` and `exit` in the main test process, but allow it in
# subprocesses where we need to test does a command properly bail out.
GHub::Commands.extend Module.new {
  main_pid = Process.pid

  [:abort, :exit].each do |method|
    define_method method do |*args|
      if Process.pid == main_pid
        raise "#{method} is disabled"
      else
        super(*args)
      end
    end
  end
}

class Minitest::Test
  # Shortcut for creating a `GHub` instance. Pass it what you would
  # normally pass `ghub` on the command line, e.g.
  #
  # shell: ghub clone rtomayko/tilt
  #  test: GHub("clone rtomayko/tilt")
  def GHub(args)
    runner = GHub::Runner.new(*args.split(' ').map {|a| a.freeze })
    runner.args.commands.each do |cmd|
      if Array === cmd and invalid = cmd.find {|c| !c.respond_to? :to_str }
        raise "#{invalid.inspect} is not a string (in #{cmd.join(' ').inspect})"
      end
    end
    runner
  end

  # Shortcut for running the `ghub` command in a subprocess. Returns
  # STDOUT as a string. Pass it what you would normally pass `ghub` on
  # the command line, e.g.
  #
  # shell: ghub clone rtomayko/tilt
  #  test: ghub("clone rtomayko/tilt")
  #
  # If a block is given it will be run in the child process before
  # execution begins. You can use this to monkeypatch or fudge the
  # environment before running ghub.
  def ghub(args, input = nil)
    parent_read, child_write = IO.pipe
    child_read, parent_write = IO.pipe if input

    fork do
      yield if block_given?
      $stdin.reopen(child_read) if input
      $stdout.reopen(child_write)
      $stderr.reopen(child_write)
      GHub(args).execute
    end
    
    if input
      parent_write.write input
      parent_write.close
    end
    child_write.close
    parent_read.read
  end

  # Asserts that `ghub` will run a specific git command based on
  # certain input.
  #
  # e.g.
  #  assert_command "clone git/ghub", "git clone git://github.com/git/ghub.git"
  #
  # Here we are saying that this:
  #   $ ghub clone git/ghub
  # Should in turn execute this:
  #   $ git clone git://github.com/git/ghub.git
  def assert_command(input, expected)
    assert_equal expected, GHub(input).command, "$ git #{input}"
  end

  def assert_commands(*expected)
    input = expected.pop
    actual = GHub(input).commands
    if expected.size != actual.size
      assert_equal expected, actual
    else
      expected.each_with_index do |expect, i|
        case expect
        when String then assert_equal expect, actual[i]
        when Regexp then assert_match expect, actual[i]
        else raise ArgumentError
        end
      end
    end
  end

  # Asserts that the command will be forwarded to git without changes
  def assert_forwarded(input)
    cmd = GHub(input)
    assert !cmd.args.changed?, "arguments were not supposed to change: #{cmd.args.inspect}"
  end

  # Asserts that `haystack` includes `needle`.
  def assert_includes(needle, haystack)
    assert haystack.include?(needle),
      "expected #{needle.inspect} in #{haystack.inspect}"
  end

  # Asserts that `haystack` does not include `needle`.
  def assert_not_includes(needle, haystack)
    assert !haystack.include?(needle),
      "didn't expect #{needle.inspect} in #{haystack.inspect}"
  end

  # Version of assert_equal tailored for big output
  def assert_output(expected, command)
    output = ghub(command) { ENV['GIT'] = 'echo' }
    assert expected == output,
      "expected:\n#{expected}\ngot:\n#{output}"
  end

  def edit_hub_config
    config = ENV['HUB_CONFIG']
    if File.exist? config
      data = YAML.load File.read(config)
    else
      data = {}
    end
    yield data
    File.open(config, 'w') { |cfg| cfg << YAML.dump(data) }
  end
end
