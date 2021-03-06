# TODO:
# - get independend from active_support (I'm so sorry...)
# - write unit tests (this is a hard one, sorry again)
%w[ uri thread curb active_support ].each { |lib| require lib }

# This is a generic interface to the MediaWiki API.
# Instead of implementing all the API functions available (and thus probably
# become outdated at some point soon) it has a very low level method
# +api_request+  taking the parameters usually send to MW's api.php and parses
# the result, thus in most cases return a hash. It than uses +method_missing+
# to seamingly map api requests to methods. There also is a generic ApiError
# for handling MW's error messages. It ships with some methods - like
# +page_content+ to ease interaction.
#
# Example:
#
#   require "mw_api"
#
#   # Displaying source of "Hauptseite" from German Wikipedia
#   puts MediaWiki.wikipedia(:de).page_content("Hauptseite")
#
#   # Logging in a bot on some local wiki.
#   wiki = MediaWiki.new "http://localhost/a_wiki/api.php"
#   wiki.login :lgname => "MyBot", :lgpassword => "password123"
#   # do something botish
#   wiki.logout
#
# Note that MediaWiki#agent is an instance of Curb::Easy. Thus you can i.e.
# load your firefox cookies and skip the login.
class MediaWiki

  # Simple wrapper around MediaWiki#loop_through. Allowing stuff like:
  #  MediaWiki.wikipedia.allpages(:apfrom => "Font").detect { |p| p["title"] =~ /^Foo/ }
  # This will not load a list of all pages, thus being somewhat more
  # efficient.
  class Walker
    include Enumerable

    def each(&block)
      @wiki.loop_through(@params, &block)
    end

    def initialize wiki, params
      @wiki, @params = wiki, params
    end
  end

  # This is a Wrapper around MW's error messages, so you don't have to check
  # the results for error messages.
  class ApiError < StandardError

    attr_reader :raw, :code, :info, :text

    def initialize error
      @raw = error
      begin
        case error
        when Hash
          @code, @info, @text = error["error"].values_at "code", "info", "*"
        when /^(unknown_[^ ]*): (.*)$/m
          @code, @info = $1, $2
        when /^---\n *error: *\n *code: +help *\n *info: *\n *\*: *|( *\n)+(.*)$/m
          @code = "help"
          @text = $2
        else
          @code = "unknown"
          @info = (error.to_s rescue error)
        end
        @text ||= @info
      rescue Exception => e
        error = e
        retry
      end
    end

    def to_s
      "#@code - #{@info ? @info : "(no #info given, try #text)"}"
    end

  end

  # Short hand for wikipedia. Same options as for MediaWiki.new.
  def self.wikipedia lang = :en, options = {}
    if lang.is_a? Hash
      lang.symbolize_keys!
      lang, options = (options[:lang] || :en), lang
    end
    self.new "http://#{lang}.wikipedia.org/w/api.php", options
  end

  attr_reader :agent

  # Takes the URI to MW's api.php and additional options.
  # Options are:
  #   verbose    - set to true for verbose mode
  #   user_agent - give a custom http user agent
  def initialize uri, options = {}
    options.symbolize_keys!
    options.reverse_merge! :verbose => false
    options.assert_valid_keys :verbose, :user_agent
    @verbose = options[:verbose]
    @uri     = uri
    @mutex   = Mutex.new
    @agent   = Curl::Easy.new do |curb|
      curb.enable_cookies        = true
      curb.follow_location       = true
      curb.multipart_form_post   = true
      curb.headers["User-Agent"] = options[:user_agent] ||
                                   "Mozilla/5.0 (compatible; MediaWiki Client " +
                                     "#{VERSION}; #{RUBY_PLATFORM})"
    end
  end

  # Are we in verbose mode?
  def verbose?
    @verbose
  end

  # Turn on verbse mode.
  def verbose!
    @verbose = true
  end

  # Turn off verbose mode.
  def silent!
    @verbose = false
  end

  # Send a http request to the given url.
  # HACK: Send post params in body (MW currently doesn't care).
  # TODO: Some fall back should happen if curb is not available.
  def http_request url, post = false
     @mutex.synchronize do
      agent.url = url.to_s
      post ? agent.http_post : agent.http_get
      agent.body_str
    end
  end

  # Generates and sends a request to api.php, parses the result. Parameter
  # format will be ignored. Add :post => true to send POST request instead
  # of GET request.
  def api_request *options
    options.flatten!
    uri       = URI.parse @uri
    params    = options.extract_options!.symbolize_keys.merge :format => :yaml
    post      = !!options.delete(:post)
    uri.query = generate_query params
    verbose "#{post ? "POST" : "GET"}: #{params.inspect}"
    result    = http_request uri, post
    begin
      raise ArgumentError unless result && result[0..3] == "---\n"
      result = YAML.load(result) || {} # This could raise an ArgumentError.
      raise ApiError, result if result.include? "error"
    rescue ArgumentError
      raise ApiError, result
    end
    result
  end

  def generate_query params
    params.each do |key, value|
      value.gsub!(/\n/, "") if value.is_a?(String) && key.to_s =~ /from$/
    end
    params.to_param
  end

  # Returns the wiki source for the given page name.
  def page_content name
    result = api :action => :query, :prop   => :revisions,
                 :titles => name,   :rvprop => :content
    return "" if result["query"]["pages"].first["missing"]
    result["query"]["pages"].first["revisions"].first["*"]
  end

  # Returns the siteinfo.
  def siteinfo
    @siteinfo ||= api(:action => :query, :meta => :siteinfo)["query"]["general"]
  end

  # Catches messages and tryes to send an api request. Does automaticly handle
  # mustbeposted error (by sending POST request) and unknown_action (by calling
  # super).
  def method_missing name, *options, &block
    begin
      params = options.extract_options!.symbolize_keys.merge :action => name
      api options, params
    rescue ApiError => e
      case e.code
      when "mustbeposted";   api :post, options, params
      when "unknown_action"; super(name, *options, &block)
      else raise e
      end
    end
  end

  # Will give you the MediaWiki::Walker for the given list.
  def list name, params = {}
    params.symbolize_keys!
    if name.is_a? Hash
      params.merge! name.symbolize_keys
    else
      params[:list] = name
    end
    Walker.new self, params
  end

  # Like list, but with a generator
  def generator name, params = {}
    name = params.symbolize_keys.merge :generator => name unless name.is_a? Hash
    list name
  end

  # For convinience.
  def allpages params = {}, &block
    return list(:allpages, params) unless block_given?
    loop_through params.merge(:list => :allpages), &block
  end

  # Loop through some list or generator.
  # Keeps sending requests until you got all pages or whatever.
  # Remember: You can always use break. Lower the limit parameter
  # of your request to load less entries you won't look at if it is
  # likely that you break up early. However, this does increase the
  # number of http requests and the overhead. If you know you are
  # going to loop through all entries, you want to set this to the
  # largest value possible.
  #
  # Do yourself a favour and ask the wiki's admins for a bot flag. This
  # will increase your maximum limit.
  def loop_through params = {}, &block
    params.symbolize_keys!
    if params.include? :list
      query_list = params[:list].to_s
      continue_list = query_list
    else
      query_list = "pages"
      continue_list = params[:generator].to_s # Note: nil.to_s == ""
    end
    loop do
      result = query params
      break if result["query"][query_list].empty?
      result["query"][query_list].each(&block)
      break unless result["query-continue"] && result["query-continue"][continue_list]
      params.merge! result["query-continue"][continue_list].symbolize_keys
    end
  end

  def inspect # :nodoc:
    "#<#{siteinfo["sitename"]} (#{siteinfo["lang"]}), #{@uri.inspect}>"
  end

  alias_method :api, :api_request
  alias_method :get, :page_content
  alias_method :[], :page_content

  private

  def verbose text = "", &block
    $stderr.puts(block ? block.call : text) if verbose?
  end

end
