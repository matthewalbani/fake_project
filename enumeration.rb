require 'yaml'
require 'json'
require 'open3'

def stringify_keys(hash)
  cvt = lambda do |h|
    Hash === h ?
        Hash[
            h.map do |k, v|
              [k.respond_to?(:to_s) ? k.to_s : k, cvt[v]]
            end
        ] : h
  end
  cvt[hash]
end

module Enumerate
  def self.list_files
    cmd = "find . -type f -not -path '*/\.*'"
    rv = Open3.popen3(cmd) do |stdin, stdout, stderr, wait|
      stdin.close

      files = []
      gemfile = nil
      while line = stdout.gets
        line.chomp!
        line.gsub!(/^\.\//, "")
        fields = splitquote(line)
        files.push(fields[0])
      end
      [wait, files]
    end
    if rv[0].value.exitstatus != 0 then
      raise "find . -type f -not -path '*/\.*' fails"
    end
    return rv[1]
  end

  def self.match(list, pat)
    return list.select { |fname| File.fnmatch?(pat, fname) }
  end

  def self.match_to_files(patterns, filenames)
    compiled_patterns = compile_pattern_sequence(patterns, nil)
    file_list = filenames.select do |f|
      match_pattern_sequence(compiled_patterns, f)
    end
    return file_list
  end

  def self.match_parallel_configs_to_files(test_configs, filenames)
    test_configs ||= []

    files_with_configs = test_configs.select do |t|
      t['mode'] == 'parallel'
    end.map do |test|
      patterns = test['files']

      if valid_pattern?(patterns)
        patterns = [patterns]
      elsif !patterns.is_a?(Array) || patterns.empty? ||
          patterns.index {|p| !valid_pattern?(p)}
        raise "parallel test config has invalid 'files': #{test}"
      end

      compiled_patterns = compile_pattern_sequence(patterns, test['prefix'])
      test['files_expanded'] = filenames.select do |f|
        match_pattern_sequence(compiled_patterns, f)
      end
      test
    end
  end


  # Compile a sequence of include/exclude patterns in our format to an
  # internal form accepted by match_pattern_sequence.
  #
  # In our include/exclude format, a pattern is either
  #  * a one-element map with key 'include' or 'exclude' and
  #    value a glob string, or
  #  * a glob string, taken as an exclude pattern.
  # The last pattern that matches a string governs whether it's
  # included or excluded.
  #
  # The caller should have already validated the format; we do not.
  def self.compile_pattern_sequence(patterns, prefix=nil)
    # The internal form is an array of [boolean, Regexp]
    # where the boolean indicates an include pattern.
    # The array is reversed from the external format,
    # i.e., the first match governs.
    patterns.reverse.map do |pat|
      if pat.is_a?(String)
        pat = File.join(prefix, pat) if prefix
        [true,
         self.compile_glob(pat)]
      else
        patstring = pat.values[0]
        patstring = File.join(prefix, patstring) if prefix
        [pat.keys[0] == 'include',
         self.compile_glob(patstring)]
      end
    end
  end

  # Compile a glob in our format -- POSIX plus **, minus character
  # classes due to laziness -- to a Ruby regexp.
  def self.compile_glob(glob)
    # The rule that wildcards don't expand to include a dot at the
    # start of a path component contributes most of the complexity
    # in the implementation, particularly in interaction with the
    # ** wildcard, which can begin new path components.
    re = '\A'
    i = 0
    nodot = true
    while i < glob.size
      nextnodot = false
      case glob[i]
        when '?'
          re << (nodot ? '[^/.]' : '[^/]')
        when '*'
          if i+1 < glob.size and glob[i+1] == '*'
            # **
            # Any sequence **, ***, ****, etc. is equivalent.
            while i+2 < glob.size and glob[i+2] == '*'
              i += 1
            end
            starstarre = '(?:[^/]*/+[^/.])*[^/]*/*' # Any string without '/.'
            # Proof sketch for complex REs below: consider leftmost [^/.], if any
            if i+2 < glob.size and glob[i+2] == '?'
              # **? (or ***? etc) -- nonempty, no '/.'
              i += 2
              re << (nodot ? "(?:/*[^/.]#{starstarre}|/+)"
              : "(?:[.]*/*[^/.]#{starstarre}|[.]*/+|[.]+)")
            else
              # ** (or *** etc), not followed by ? -- any string without '/.'
              i += 1
              re << (nodot ? "(?:/*[^/.]#{starstarre}|/*)"
              : starstarre)
            end
          elsif i+1 < glob.size and glob[i+1] == '?'
            # *?
            i += 1
            re << (nodot ? '[^/.][^/]*' : '[^/]+')
          else
            # plain *, not followed by ?
            re << (nodot ? '(?:[^/.][^/]*|)' : '[^/]*')
          end
        when '\\'
          case i+1 < glob.size and glob[i+1]
            when *%w(? * \\ [)
              re << "\\#{glob[i+1]}"
              i += 1
            else # including false, for end of pattern
              raise "Bad escape sequence in glob: #{glob}"
          end
        when '['
          raise "Character classes not supported, in glob: #{glob}"
        when '/'
          nextnodot = true
          re << '/'
        when /[a-zA-Z0-9]/
          re << glob[i]
        else
          re << "\\#{glob[i]}"
      end
      i += 1
      nodot = nextnodot
    end
    re << '\z'
    Regexp.new(re)
  end

  # Determine if a string is included or excluded by the given patterns,
  # which must have been compiled by compile_pattern_sequence.
  def self.match_pattern_sequence(compiled_patterns, s)
    # See the comment inside compile_pattern_sequence on the format.
    compiled_patterns.each do |incl, re|
      return incl if re.match(s)
    end
    return false
  end

  # Internal to match_parallel_configs_to_files.
  def self.valid_pattern?(pattern)
    pattern.is_a?(String) ||
        (pattern.is_a?(Hash) &&
            pattern.size == 1 &&
            %w(include exclude).index(pattern.keys[0]) &&
            pattern.values[0].is_a?(String))
  end

  def self.splitquote(s)
    fields = []
    str = ''
    esc = false     # last character was an escape
    quote = false   # inside quotes
    s.chars do |c|
      if esc then
        case c
          when "t"
            str += "\t"
          when "n"
            str += "\n"
          else
            str += c
        end
        esc = false
        next
      elsif c == '\\' then
        esc = true
        next
      end
      if c == '"' then
        quote = !quote
      elsif !quote && c =~ /\s/ then
        if !str.empty? then
          fields.push(str)
          str = ''
        end
      else
        str += c
      end
    end
    if !str.empty? then
      fields.push(str)
    end
    return fields
  end
end

require 'json'
require 'yaml'
require 'net/http'
require 'octokit'

module Integration_test
  def generate_solano_plan
    begin
      unless ENV['DISABLE_FILTERED_RUN'] == "true" || ENV['TDDIUM_PR_BRANCH'].blank?
        jira_ticket_reference = extract_jira_ticket(ENV['TDDIUM_PR_BRANCH'])

      unless jira_ticket_reference.present?
        pr_number = ENV['TDDIUM_PR_ID'] || ENV['TDDIUM_PR_BRANCH']
        pull_request_title = extract_git_pull_request_title(pr_number)
        jira_ticket_reference = extract_jira_ticket(pull_request_title)
      end

        p "Jira ticket extracted: #{jira_ticket_reference}" if ENV['VERBOSE']

        if jira_ticket_reference.present?
          uribase = "https://coupadev.atlassian.net"
          apipath = "/rest/api/latest"

          uri = URI("#{uribase}#{apipath}")
          https = Net::HTTP.new(uri.host, uri.port)
          https.use_ssl = true
          headers = {
              'Content-Type' => 'application/json',
              'Authorization' => "Basic #{ENV['JIRA_BASIC_AUTH_TOKEN']}"
          }

          uri.path = "#{apipath}/issue/#{jira_ticket_reference.upcase}"
          uri.query = URI.encode_www_form(:fields => [:components])

          response = https.get(uri.to_s, headers)

          p "Jira response: #{response.body}" if ENV['VERBOSE']

          parsed_response = JSON.parse(response.body)
          components = parsed_response["fields"]["components"]
          component_list = components.map { |c| c["name"] }.join(", ")

          p "Components list: #{component_list}" if ENV['VERBOSE']

          if component_list.present?
            mapping_yml = YAML.load_file('./config/integration_test_mapping.yml')

            components = component_list.gsub(/\s+/, '').split(',')
            components = components - ["FunctionalAutomation"]
            if components.size == 1
              @next_profile = mapping_yml['components'][components.first.underscore]
            elsif components.size > 1
              @next_profile = multi_component_profile(components)
            end
          end
        end
      end
    rescue StandardError => e
      p "Jira components fetch failed #{e}"
    end

    if @next_profile
      p "Chose #{@next_profile} profile"
    else
      @next_profile = 'default'
      p "Couldn't match any any/all Jira components; defaulting to run all integration tests"
    end

    generate_test_files_json @next_profile
  end
end

def multi_component_profile(components)
  approvals_profile_components = ['Accounts', 'Approvals', 'Requisitions', 'Invoicing', 'Expenses', 'PurchaseOrders']
  if (components - approvals_profile_components).blank?
    'approvals'
  elsif (components - ['Approvals', 'Contracts']).blank?
    'approvals_contracts'
  elsif (components - ['Requisitions', 'Supplier']).blank?
    'requisitions_suppliers'
  elsif (components - ['Contracts', 'Invoicing']).blank?
    'contracts_invoicing'
  elsif (components - ['Invoicing', 'Receiving']).blank?
    'invoicing_receiving'
  elsif (components - ['Invoicing', 'Budgeting']).blank?
    'invoicing_budgeting'
  end
end

def extract_jira_ticket(branch_name)
  branch_name =~ /(cd|jz|cm)(-|_)?\s*(\d+)/i ? "#{$1}-#{$3}" : nil
end

def extract_git_pull_request_title(pr_branch_name)
  client = Octokit::Client.new(:access_token => ENV['GIT_TOKEN'])
  user = client.user
  user.login
  pr_number = pr_branch_name.split('/').reject { |prefix| prefix =='pr' || prefix =='merge' }.first
  client.issue('coupa/coupa_development', pr_number)[:title]
end

def generate_test_files_json(profile_name)
  if profile_name.nil? || profile_name.strip.empty? then
    if File.exists?('solano-plan-variables.json') then
      vars = JSON.parse(File.read('solano-plan-variables.json')) || {}
      profile_name = vars['next_profile']
    end
    if profile_name.nil? || profile_name.strip.empty? then
      abort "missing profile name"
    end
  end
  profile_name = profile_name.strip

  config = nil
  %w(solano.yml config/solano.yml tddium.yml config/tddium.yml).each do |path|
    if File.exist?(path) then
      config = YAML.load_file(path)
      break
    end
  end

  if config.nil? then
    abort "No solano configuration found"
  end

  config = stringify_keys(config)
  profile_config = config['profiles']
  if profile_config.nil? then
    abort "No profiles defined"
  end

  profile_config = profile_config[profile_name]
  if profile_config.nil? then
    abort "No such profile '#{profile_name}'"
  end

  case profile_config['test_pattern']
    when String
      profile_config['test_pattern'] = [profile_config['test_pattern']]
    when Array
      # Nothing
    when NilClass
      profile_config['test_pattern'] = []
    else
      raise "Malformed 'test_pattern' in profile '#{profile_name}'"
  end

  case profile_config['tests']
    when String
      profile_config['tests'] = [profile_config['tests']]
    when Array
      # Nothing
    when NilClass
      profile_config['tests'] = []
    else
      raise "Malformed 'tests' in profile '#{profile_name}'"
  end

  test_patterns = config['test_pattern'] || []
  test_patterns += profile_config['test_pattern'] || []

  files = Enumerate.list_files
  file_list = Enumerate.match_to_files(test_patterns, files)
  file_list = file_list.uniq

  commands = config['tests'] || []
  commands += profile_config['tests'] || []
  parallel_commands = Enumerate.match_parallel_configs_to_files(commands, files)
  commands = []
  #commands = commands.select { |v| v['mode'] != 'parallel' }
  commands += parallel_commands

  to_run = {'tests' => file_list, 'commands' => commands}

  File.open("test_list.json", "w") do |f|
    f.write(JSON.pretty_generate(to_run))
  end

  puts 'Generated test_list.json'
end

include Integration_test
generate_solano_plan
