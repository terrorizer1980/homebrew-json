# typed: true
# frozen_string_literal: true

require "formula_installer"

module Homebrew
  extend T::Sig

  module_function

  FORMULAE_BREW_SH_BOTTLE_API_DOMAIN = Pathname.new("https://formulae.brew.sh/api/bottle").freeze
  GITHUB_PACKAGES_SHA256_REGEX = %r{#{GitHubPackages::URL_REGEX}.*/blobs/sha256:(?<sha256>\h{64})$}.freeze

  sig { returns(CLI::Parser) }
  def json_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Install a <formula> from a JSON file.

        A <formula> can be specified by name, a JSON file, or a URL.
      EOS

      named_args [:formula, :file, :url], min: 1
    end
  end

  sig { void }
  def json
    args = json_args.parse

    args.named.each do |arg|
      json = if File.exist? arg
        File.read(arg)
      else
        arg = FORMULAE_BREW_SH_BOTTLE_API_DOMAIN/"#{arg}.json" unless arg.start_with? %r{https?://}

        output = curl_output("--fail", arg.to_s)
        odie "No JSON file found at #{Tty.underline}#{arg}#{Tty.reset}" unless output.success?

        output.stdout
      end

      begin
        hash = JSON.parse(json)
      rescue JSON::ParserError
        odie "Invalid JSON file: #{Tty.underline}#{arg}#{Tty.reset}"
      end

      name = hash["name"]
      bottles = download_bottles hash

      formula = Formulary.factory bottles[name]
      install_formula formula, args: install_args(args: args)
    end
  end

  sig { params(url: String).returns(T.nilable(String)) }
  def checksum_from_url(url)
    match = url.match GITHUB_PACKAGES_SHA256_REGEX
    return if match.blank?

    match[:sha256]
  end

  sig { params(hash: Hash).returns(T::Hash[String, Pathname]) }
  def download_bottles(hash)
    bottle_tag = Utils::Bottles.tag.to_s
    bottles = {}

    odie "No bottle availabe for current OS" unless hash["bottles"].key? bottle_tag

    bottles[hash["name"]] = download_bottle(hash, bottle_tag)

    hash["dependencies"].each do |dep_hash|
      bottles[dep_hash["name"]] = download_bottle(dep_hash, bottle_tag)
    end

    bottles
  end

  sig { params(hash: Hash, tag: String).returns(Pathname) }
  def download_bottle(hash, tag)
    bottle = hash["bottles"][tag]
    return if bottle.blank?

    sha256 = bottle["sha256"] || checksum_from_url(bottle["url"])
    bottle_filename = Bottle::Filename.new(hash["name"], hash["pkg_version"], tag, hash["rebuild"])

    resource = Resource.new hash["name"]
    resource.url bottle["url"]
    resource.sha256 sha256
    resource.downloader.resolved_basename = bottle_filename

    resource.fetch
  end

  def install_args(args:)
    result = OpenStruct.new
    result[:debug] = args.debug?
    result[:quiet] = args.quiet?
    result[:verbose] = args.verbose?
    result
  end

  # Copied directly from the install command
  def install_formula(f, args:)
    f.print_tap_action
    build_options = f.build

    fi = FormulaInstaller.new(
      f,
      **{
        options:                    build_options.used_options,
        build_bottle:               args.build_bottle?,
        force_bottle:               args.force_bottle?,
        bottle_arch:                args.bottle_arch,
        ignore_deps:                args.ignore_dependencies?,
        only_deps:                  args.only_dependencies?,
        include_test_formulae:      args.include_test_formulae,
        build_from_source_formulae: args.build_from_source_formulae,
        cc:                         args.cc,
        git:                        args.git?,
        interactive:                args.interactive?,
        keep_tmp:                   args.keep_tmp?,
        force:                      args.force?,
        debug:                      args.debug?,
        quiet:                      args.quiet?,
        verbose:                    args.verbose?,
      }.compact,
    )
    fi.prelude
    fi.fetch
    fi.install
    fi.finish
  rescue FormulaInstallationAlreadyAttemptedError
    # We already attempted to install f as part of the dependency tree of
    # another formula. In that case, don't generate an error, just move on.
    nil
  rescue CannotInstallFormulaError => e
    ofail e.message
  end
end
