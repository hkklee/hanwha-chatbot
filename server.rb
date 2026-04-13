require 'webrick'
require 'net/http'
require 'uri'
require 'json'

# ── Load environment ──
ENV_FILE = File.join(__dir__, '.env.local')
if File.exist?(ENV_FILE)
  File.readlines(ENV_FILE).each do |line|
    line.strip!
    next if line.empty? || line.start_with?('#')
    key, value = line.split('=', 2)
    ENV[key.strip] = value.strip if key && value
  end
end

API_KEY = ENV['ANTHROPIC_API_KEY'] || ''
abort("ANTHROPIC_API_KEY not found in .env.local") if API_KEY.empty?

# ── Load system prompts + product data ──
PRODUCT_DATA = File.read(File.join(__dir__, 'products.json'))

PROMPTS = {
  'customer' => File.read(File.join(__dir__, 'system-prompt.txt')) +
                "\n\n<product_data>\n#{PRODUCT_DATA}\n</product_data>",
  'internal' => File.read(File.join(__dir__, 'system-prompt-internal.txt')) +
                "\n\n<product_data>\n#{PRODUCT_DATA}\n</product_data>"
}

PORT = (ENV['PORT'] || 8080).to_i

# ── WEBrick server ──
server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: '0.0.0.0',
  DocumentRoot: __dir__,
  Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO),
  AccessLog: [[File.open(File::NULL, 'w'), WEBrick::AccessLog::COMMON_LOG_FORMAT]]
)

# ── Chat API endpoint ──
server.mount_proc '/api/chat' do |req, res|
  res['Content-Type'] = 'application/json'
  res['Access-Control-Allow-Origin'] = '*'
  res['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
  res['Access-Control-Allow-Headers'] = 'Content-Type'

  if req.request_method == 'OPTIONS'
    res.status = 204
    next
  end

  unless req.request_method == 'POST'
    res.status = 405
    res.body = JSON.generate({ error: 'Method not allowed' })
    next
  end

  begin
    body = JSON.parse(req.body)
    messages = body['messages'] || []
    mode = body['mode'] || 'customer'
    system_prompt = PROMPTS[mode] || PROMPTS['customer']

    # Call Anthropic API
    uri = URI('https://api.anthropic.com/v1/messages')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60
    http.open_timeout = 10

    api_body = {
      model: 'claude-sonnet-4-20250514',
      max_tokens: 2048,
      system: system_prompt,
      messages: messages
    }

    api_req = Net::HTTP::Post.new(uri)
    api_req['Content-Type'] = 'application/json'
    api_req['x-api-key'] = API_KEY
    api_req['anthropic-version'] = '2023-06-01'
    api_req.body = JSON.generate(api_body)

    api_res = http.request(api_req)

    if api_res.code.to_i == 200
      result = JSON.parse(api_res.body)
      text = result['content']&.find { |c| c['type'] == 'text' }&.dig('text') || ''
      res.body = JSON.generate({ reply: text })
    else
      $stderr.puts "Anthropic API error: #{api_res.code} #{api_res.body}"
      res.status = 502
      res.body = JSON.generate({ error: "API error: #{api_res.code}", detail: api_res.body })
    end

  rescue JSON::ParserError => e
    res.status = 400
    res.body = JSON.generate({ error: 'Invalid JSON', detail: e.message })
  rescue StandardError => e
    $stderr.puts "Server error: #{e.message}"
    res.status = 500
    res.body = JSON.generate({ error: 'Internal server error', detail: e.message })
  end
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

puts "Hanwha Chatbot Server running at http://localhost:#{PORT}"
PROMPTS.each { |k, v| puts "  #{k} prompt: #{v.length} chars" }
server.start
