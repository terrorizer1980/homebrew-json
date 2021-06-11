# frozen_string_literal: true

require "formula_installer"

module Homebrew
  module_function

  FORMULAE_BREW_SH_BOTTLE_API_DOMAIN = Pathname.new("https://formulae.brew.sh/api/bottle").freeze
  GITHUB_PACKAGES_SHA256_REGEX = %r{#{GitHubPackages::URL_REGEX}.*/blobs/sha256:(?<sha256>\h{64})$}.freeze

  def json_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Install a <formula> from a JSON file.

        A <formula> can be specified by name, a JSON file, or a URL.
      EOS
      switch "-f", "--force",
             description: "Install formulae without checking for previously installed keg-only or " \
                          "non-migrated versions."
      switch "--keep-tmp",
             description: "Retain the temporary files created during installation."
      switch "--display-times",
             env:         :display_install_times,
             description: "Print install times for each formula at the end of the run."

      named_args [:formula, :file, :url], min: 1
    end
  end

  def json
    args = json_args.parse

    formulae = args.named.map do |arg|
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
      formula = Formulary.factory(bottles[name])

      formula if Install.install_formula? formula, force: args.force?, quiet: args.quiet?
    end.compact

    return if formulae.empty?

    Install.perform_preinstall_checks

    formulae.each do |formula|
      Migrator.migrate_if_needed(formula, force: args.force?)
      Install.install_formula(
        formula,
        keep_tmp: args.keep_tmp?,
        force:    args.force?,
        debug:    args.debug?,
        quiet:    args.quiet?,
        verbose:  args.verbose?,
      )
      Cleanup.install_formula_clean!(formula)
    end

    Upgrade.check_installed_dependents(
      formulae,
      flags:                args.flags_only,
      installed_on_request: true,
      keep_tmp:             args.keep_tmp?,
      force:                args.force?,
      debug:                args.debug?,
      quiet:                args.quiet?,
      verbose:              args.verbose?,
    )

    Homebrew.messages.display_messages(display_times: args.display_times?)
  end

  def checksum_from_url(url)
    match = url.match GITHUB_PACKAGES_SHA256_REGEX
    return if match.blank?

    match[:sha256]
  end

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

  def download_bottle(hash, tag)
    bottle = hash["bottles"][tag]
    return if bottle.blank?

    sha256 = bottle["sha256"] || checksum_from_url(bottle["url"])
    bottle_filename = Bottle::Filename.new(hash["name"], hash["pkg_version"], tag, hash["rebuild"])

    resource = Resource.new hash["name"]
    resource.url bottle["url"]
    resource.sha256 sha256
    resource.version hash["pkg_version"]
    resource.downloader.resolved_basename = bottle_filename

    # Map the name of this formula to the local bottle path to allow the
    # formula to be loaded by passing just the name to `Formulary::factory`.
    ENV["HOMEBREW_BOTTLE_JSON"] = "1"
    Formulary.map_formula_name_to_local_bottle_path hash["name"], resource.downloader.cached_location

    resource.fetch
  end
end
