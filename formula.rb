require "formula_support"
require "formula_lock"
require "formula_pin"
require "hardware"
require "bottles"
require "build_environment"
require "build_options"
require "formulary"
require "software_spec"
require "install_renamed"
require "pkg_version"
require "tap"
require "formula_renames"
require "keg"
require "migrator"

# A formula provides instructions and metadata for Homebrew to install a piece
# of software. Every Homebrew formula is a {Formula}.
# All subclasses of {Formula} (and all Ruby classes) have to be named
# `UpperCase` and `not-use-dashes`.
# A formula specified in `this-formula.rb` should have a class named
# `ThisFormula`. Homebrew does enforce that the name of the file and the class
# correspond.
# Make sure you check with `brew search` that the name is free!
# @abstract
# @see SharedEnvExtension
# @see FileUtils
# @see Pathname
# @see http://www.rubydoc.info/github/Homebrew/homebrew/file/share/doc/homebrew/Formula-Cookbook.md Formula Cookbook
# @see https://github.com/styleguide/ruby Ruby Style Guide
#
# <pre>class Wget < Formula
#   homepage "https://www.gnu.org/software/wget/"
#   url "https://ftp.gnu.org/gnu/wget/wget-1.15.tar.gz"
#   sha256 "52126be8cf1bddd7536886e74c053ad7d0ed2aa89b4b630f76785bac21695fcd"
#
#   def install
#     system "./configure", "--prefix=#{prefix}"
#     system "make", "install"
#   end
# end</pre>
class Formula
  include FileUtils
  include Utils::Inreplace
  extend Enumerable

  # @!method inreplace(paths, before = nil, after = nil)
  # Actually implemented in {Utils::Inreplace.inreplace}.
  # Sometimes we have to change a bit before we install. Mostly we
  # prefer a patch but if you need the `prefix` of this formula in the
  # patch you have to resort to `inreplace`, because in the patch
  # you don't have access to any var defined by the formula. Only
  # HOMEBREW_PREFIX is available in the embedded patch.
  # inreplace supports regular expressions.
  # <pre>inreplace "somefile.cfg", /look[for]what?/, "replace by #{bin}/tool"</pre>
  # @see Utils::Inreplace.inreplace

  # The name of this {Formula}.
  # e.g. `this-formula`
  attr_reader :name

  # The fully-qualified name of this {Formula}.
  # For core formula it's the same as {#name}.
  # e.g. `homebrew/tap-name/this-formula`
  attr_reader :full_name

  # The full path to this {Formula}.
  # e.g. `/usr/local/Library/Formula/this-formula.rb`
  attr_reader :path

  # The {Tap} instance associated with this {Formula}.
  # If it's <code>nil</code>, then this formula is loaded from path or URL.
  # @private
  attr_reader :tap

  # The stable (and default) {SoftwareSpec} for this {Formula}
  # This contains all the attributes (e.g. URL, checksum) that apply to the
  # stable version of this formula.
  # @private

  attr_reader :stable

  # The development {SoftwareSpec} for this {Formula}.
  # Installed when using `brew install --devel`
  # `nil` if there is no development version.
  # @see #stable
  # @private
  attr_reader :devel

  # The HEAD {SoftwareSpec} for this {Formula}.
  # Installed when using `brew install --HEAD`
  # This is always installed with the version `HEAD` and taken from the latest
  # commit in the version control system.
  # `nil` if there is no HEAD version.
  # @see #stable
  # @private
  attr_reader :head

  # The currently active {SoftwareSpec}.
  # @see #determine_active_spec
  attr_reader :active_spec
  protected :active_spec

  # A symbol to indicate currently active {SoftwareSpec}.
  # It's either :stable, :devel or :head
  # @see #active_spec
  # @private
  attr_reader :active_spec_sym

  # Used for creating new Homebrew versions of software without new upstream
  # versions.
  # @see .revision
  attr_reader :revision

  # The current working directory during builds.
  # Will only be non-`nil` inside {#install}.
  attr_reader :buildpath

  # The current working directory during tests.
  # Will only be non-`nil` inside {#test}.
  attr_reader :testpath

  # When installing a bottle (binary package) from a local path this will be
  # set to the full path to the bottle tarball. If not, it will be `nil`.
  # @private
  attr_accessor :local_bottle_path

  # The {BuildOptions} for this {Formula}. Lists the arguments passed and any
  # {#options} in the {Formula}. Note that these may differ at different times
  # during the installation of a {Formula}. This is annoying but the result of
  # state that we're trying to eliminate.
  # @return [BuildOptions]
  attr_accessor :build

  # @private
  def initialize(name, path, spec)
    @name = name
    @path = path
    @revision = self.class.revision || 0

    if path == Formulary.core_path(name)
      @tap = CoreFormulaRepository.instance
      @full_name = name
    elsif path.to_s =~ HOMEBREW_TAP_PATH_REGEX
      @tap = Tap.fetch($1, $2)
      @full_name = "#{@tap}/#{name}"
    else
      @tap = nil
      @full_name = name
    end

    set_spec :stable
    set_spec :devel
    set_spec :head

    @active_spec = determine_active_spec(spec)
    @active_spec_sym = if head?
      :head
    elsif devel?
      :devel
    else
      :stable
    end
    validate_attributes!
    @build = active_spec.build
    @pin = FormulaPin.new(self)
  end

  # @private
  def set_active_spec(spec_sym)
    spec = send(spec_sym)
    raise FormulaSpecificationError, "#{spec_sym} spec is not available for #{full_name}" unless spec
    @active_spec = spec
    @active_spec_sym = spec_sym
    validate_attributes!
    @build = active_spec.build
  end

  private

  def set_spec(name)
    spec = self.class.send(name)
    if spec.url
      spec.owner = self
      instance_variable_set("@#{name}", spec)
    end
  end

  def determine_active_spec(requested)
    spec = send(requested) || stable || devel || head
    spec || raise(FormulaSpecificationError, "formulae require at least a URL")
  end

  def validate_attributes!
    if name.nil? || name.empty? || name =~ /\s/
      raise FormulaValidationError.new(full_name, :name, name)
    end

    url = active_spec.url
    if url.nil? || url.empty? || url =~ /\s/
      raise FormulaValidationError.new(full_name, :url, url)
    end

    val = version.respond_to?(:to_str) ? version.to_str : version
    if val.nil? || val.empty? || val =~ /\s/
      raise FormulaValidationError.new(full_name, :version, val)
    end
  end

  public

  # Is the currently active {SoftwareSpec} a {#stable} build?
  # @private
  def stable?
    active_spec == stable
  end

  # Is the currently active {SoftwareSpec} a {#devel} build?
  # @private
  def devel?
    active_spec == devel
  end

  # Is the currently active {SoftwareSpec} a {#head} build?
  # @private
  def head?
    active_spec == head
  end

  # @private
  def bottle_unneeded?
    active_spec.bottle_unneeded?
  end

  # @private
  def bottle_disabled?
    active_spec.bottle_disabled?
  end

  # @private
  def bottle_disable_reason
    active_spec.bottle_disable_reason
  end

  # Does the currently active {SoftwareSpec} has any bottle?
  # @private
  def bottle_defined?
    active_spec.bottle_defined?
  end

  # Does the currently active {SoftwareSpec} has an installable bottle?
  # @private
  def bottled?
    active_spec.bottled?
  end

  # @private
  def bottle_specification
    active_spec.bottle_specification
  end

  # The Bottle object for the currently active {SoftwareSpec}.
  # @private
  def bottle
    Bottle.new(self, bottle_specification) if bottled?
  end

  # The description of the software.
  # @see .desc
  def desc
    self.class.desc
  end

  # The homepage for the software.
  # @see .homepage
  def homepage
    self.class.homepage
  end

  # The version for the currently active {SoftwareSpec}.
  # The version is autodetected from the URL and/or tag so only needs to be
  # declared if it cannot be autodetected correctly.
  # @see .version
  def version
    active_spec.version
  end

  # The {PkgVersion} for this formula with {version} and {#revision} information.
  def pkg_version
    PkgVersion.new(version, revision)
  end

  # A named Resource for the currently active {SoftwareSpec}.
  # Additional downloads can be defined as {#resource}s.
  # {Resource#stage} will create a temporary directory and yield to a block.
  # <pre>resource("additional_files").stage { bin.install "my/extra/tool" }</pre>
  def resource(name)
    active_spec.resource(name)
  end

  # An old name for the formula
  def oldname
    @oldname ||= if tap
      formula_renames = tap.formula_renames
      if formula_renames.value?(name)
        formula_renames.to_a.rassoc(name).first
      end
    end
  end

  # All of aliases for the formula
  def aliases
    @aliases ||= if tap
      tap.alias_reverse_table[full_name] || []
    else
      []
    end
  end

  # The {Resource}s for the currently active {SoftwareSpec}.
  def resources
    active_spec.resources.values
  end

  # The {Dependency}s for the currently active {SoftwareSpec}.
  # @private
  def deps
    active_spec.deps
  end

  # The {Requirement}s for the currently active {SoftwareSpec}.
  # @private
  def requirements
    active_spec.requirements
  end

  # The cached download for the currently active {SoftwareSpec}.
  # @private
  def cached_download
    active_spec.cached_download
  end

  # Deletes the download for the currently active {SoftwareSpec}.
  # @private
  def clear_cache
    active_spec.clear_cache
  end

  # The list of patches for the currently active {SoftwareSpec}.
  # @private
  def patchlist
    active_spec.patches
  end

  # The options for the currently active {SoftwareSpec}.
  # @private
  def options
    active_spec.options
  end

  # The deprecated options for the currently active {SoftwareSpec}.
  # @private
  def deprecated_options
    active_spec.deprecated_options
  end

  # The deprecated option flags for the currently active {SoftwareSpec}.
  # @private
  def deprecated_flags
    active_spec.deprecated_flags
  end

  # If a named option is defined for the currently active {SoftwareSpec}.
  def option_defined?(name)
    active_spec.option_defined?(name)
  end

  # All the {.fails_with} for the currently active {SoftwareSpec}.
  # @private
  def compiler_failures
    active_spec.compiler_failures
  end

  # If this {Formula} is installed.
  # This is actually just a check for if the {#installed_prefix} directory
  # exists and is not empty.
  # @private
  def installed?
    (dir = installed_prefix).directory? && dir.children.length > 0
  end

  # If at least one version of {Formula} is installed.
  # @private
  def any_version_installed?
    require "tab"
    installed_prefixes.any? { |keg| (keg/Tab::FILENAME).file? }
  end

  # @private
  # The `LinkedKegs` directory for this {Formula}.
  # You probably want {#opt_prefix} instead.
  def linked_keg
    Pathname.new("#{HOMEBREW_LIBRARY}/LinkedKegs/#{name}")
  end

  # The latest prefix for this formula. Checks for {#head}, then {#devel}
  # and then {#stable}'s {#prefix}
  # @private
  def installed_prefix
    if head && (head_prefix = prefix(PkgVersion.new(head.version, revision))).directory?
      head_prefix
    elsif devel && (devel_prefix = prefix(PkgVersion.new(devel.version, revision))).directory?
      devel_prefix
    elsif stable && (stable_prefix = prefix(PkgVersion.new(stable.version, revision))).directory?
      stable_prefix
    else
      prefix
    end
  end

  # The currently installed version for this formula. Will raise an exception
  # if the formula is not installed.
  # @private
  def installed_version
    Keg.new(installed_prefix).version
  end

  # The directory in the cellar that the formula is installed to.
  # This directory contains the formula's name and version.
  def prefix(v = pkg_version)
    Pathname.new("#{HOMEBREW_CELLAR}/#{name}/#{v}")
  end

  # The parent of the prefix; the named directory in the cellar containing all
  # installed versions of this software
  # @private
  def rack
    prefix.parent
  end

  # All of current installed prefix directories.
  # @private
  def installed_prefixes
    rack.directory? ? rack.subdirs : []
  end

  # All of current installed kegs.
  # @private
  def installed_kegs
    installed_prefixes.map { |dir| Keg.new(dir) }
  end

  # The directory where the formula's binaries should be installed.
  # This is symlinked into `HOMEBREW_PREFIX` after installation or with
  # `brew link` for formulae that are not keg-only.
  #
  # Need to install into the {.bin} but the makefile doesn't mkdir -p prefix/bin?
  # <pre>bin.mkpath</pre>
  #
  # No `make install` available?
  # <pre>bin.install "binary1"</pre>
  def bin
    prefix+"bin"
  end

  # The directory where the formula's documentation should be installed.
  # This is symlinked into `HOMEBREW_PREFIX` after installation or with
  # `brew link` for formulae that are not keg-only.
  def doc
    share+"doc"+name
  end

  # The directory where the formula's headers should be installed.
  # This is symlinked into `HOMEBREW_PREFIX` after installation or with
  # `brew link` for formulae that are not keg-only.
  #
  # No `make install` available?
  # <pre>include.install "example.h"</pre>
  def include
    prefix+"include"
  end

  # The directory where the formula's info files should be installed.
  # This is symlinked into `HOMEBREW_PREFIX` after installation or with
  # `brew link` for formulae that are not keg-only.
  def info
    share+"info"
  end

  # The directory where the formula's libraries should be installed.
  # This is symlinked into `HOMEBREW_PREFIX` after installation or with
  # `brew link` for formulae that are not keg-only.
  #
  # No `make install` available?
  # <pre>lib.install "example.dylib"</pre>
  def lib
    prefix+"lib"
  end
  . . .

  public

  # To call out to the system, we use the `system` method and we prefer
  # you give the args separately as in the line below, otherwise a subshell
  # has to be opened first.
  # <pre>system "./bootstrap.sh", "--arg1", "--prefix=#{prefix}"</pre>
  #
  # For CMake we have some necessary defaults in {#std_cmake_args}:
  # <pre>system "cmake", ".", *std_cmake_args</pre>
  #
  # If the arguments given to configure (or make or cmake) are depending
  # on options defined above, we usually make a list first and then
  # use the `args << if <condition>` to append to:
  # <pre>args = ["--with-option1", "--with-option2"]
  #
  # # Most software still uses `configure` and `make`.
  # # Check with `./configure --help` what our options are.
  # system "./configure", "--disable-debug", "--disable-dependency-tracking",
  #                       "--disable-silent-rules", "--prefix=#{prefix}",
  #                       *args # our custom arg list (needs `*` to unpack)
  #
  # # If there is a "make", "install" available, please use it!
  # system "make", "install"</pre>
  def system(cmd, *args)
    verbose = ARGV.verbose?
    verbose_using_dots = !ENV["HOMEBREW_VERBOSE_USING_DOTS"].nil?

    # remove "boring" arguments so that the important ones are more likely to
    # be shown considering that we trim long ohai lines to the terminal width
    pretty_args = args.dup
    if cmd == "./configure" && !verbose
      pretty_args.delete "--disable-dependency-tracking"
      pretty_args.delete "--disable-debug"
    end
    pretty_args.each_index do |i|
      if pretty_args[i].to_s.start_with? "import setuptools"
        pretty_args[i] = "import setuptools..."
      end
    end
    ohai "#{cmd} #{pretty_args*" "}".strip

    @exec_count ||= 0
    @exec_count += 1
    logfn = "#{logs}/%02d.%s" % [@exec_count, File.basename(cmd).split(" ").first]
    logs.mkpath

    File.open(logfn, "w") do |log|
      log.puts Time.now, "", cmd, args, ""
      log.flush

      if verbose
        rd, wr = IO.pipe
        begin
          pid = fork do
            rd.close
            log.close
            exec_cmd(cmd, args, wr, logfn)
          end
          wr.close

          if verbose_using_dots
            last_dot = Time.at(0)
            while buf = rd.gets
              log.puts buf
              # make sure dots printed with interval of at least 1 min.
              if (Time.now - last_dot) > 60
                print "."
                $stdout.flush
                last_dot = Time.now
              end
            end
            puts
          else
            while buf = rd.gets
              log.puts buf
              puts buf
            end
          end
        ensure
          rd.close
        end
      else
        pid = fork { exec_cmd(cmd, args, log, logfn) }
      end

      Process.wait(pid)

      $stdout.flush

      unless $?.success?
        log_lines = ENV["HOMEBREW_FAIL_LOG_LINES"]
        log_lines ||= "15"

        log.flush
        if !verbose || verbose_using_dots
          puts "Last #{log_lines} lines from #{logfn}:"
          Kernel.system "/usr/bin/tail", "-n", log_lines, logfn
        end
        log.puts

        require "cmd/config"
        require "build_environment"

        env = ENV.to_hash

        Homebrew.dump_verbose_config(log)
        log.puts
        Homebrew.dump_build_env(env, log)

        raise BuildError.new(self, cmd, args, env)
      end
    end
  end

  private

  def exec_cmd(cmd, args, out, logfn)
    ENV["HOMEBREW_CC_LOG_PATH"] = logfn

    # TODO: system "xcodebuild" is deprecated, this should be removed soon.
    if cmd.to_s.start_with? "xcodebuild"
      ENV.remove_cc_etc
    end

    # Turn on argument filtering in the superenv compiler wrapper.
    # We should probably have a better mechanism for this than adding
    # special cases to this method.
    if cmd == "python"
      setup_py_in_args = %w[setup.py build.py].include?(args.first)
      setuptools_shim_in_args = args.any? { |a| a.to_s.start_with? "import setuptools" }
      if setup_py_in_args || setuptools_shim_in_args
        ENV.refurbish_args
      end
    end

    $stdout.reopen(out)
    $stderr.reopen(out)
    out.close
    args.collect!(&:to_s)
    exec(cmd, *args) rescue nil
    puts "Failed to execute: #{cmd}"
    exit! 1 # never gets here unless exec threw or failed
  end
