#!/usr/bin/ruby
require 'socket'
require 'json'
require 'ipaddr'
require 'set'
require 'base64'

# Use a Set to store unique peers
$peers = Set.new

# Add initial peers
[
  ['148.71.89.128', 24254],
  ['159.69.54.127', 24254]
].each do |host, port|
  $peers << [IPAddr.new(host), port]
end

# Create a UDP socket
socket = UDPSocket.new
socket.bind('0.0.0.0', 24257)
# Allow broadcasting
socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)

puts "Listening on UDP port 24257..."

# Function to send request for peers
def send_request(socket)
  return if $peers.empty?
  peer = $peers.to_a.sample
  host, port = peer
  puts "requesting peers" + " from " + host.to_s + ":" + port.to_s
  msg = [{PleaseSendPeers:{}}].to_json
  socket.send(msg, 0, host.to_s, port)
end

# Function to send $peers
def send_peers(socket, addr)
  peer_list = $peers.map { |peer| "#{peer.first}:#{peer.last}" }
  msg = [{Peers: {peers: peer_list}}].to_json
  socket.send(msg, 0, addr[3], addr[1])
end

                          
def send_content(socket, id, offset, length, addr)
  filename = "shared/#{id}"
  return if id.include?('/') # security check
  begin
    File.open(filename, 'rb') do |f|
      f.seek(offset)
      data = f.read(length)
      file_size = f.size
      encoded_data = Base64.strict_encode64(data)
      msg = [{Content: {
        id: id,
        base64: encoded_data,
        eof: file_size,
        offset: offset
      }}].to_json
      socket.send(msg, 0, addr[3], addr[1])
    end
  rescue Errno::ENOENT
    # file not found, ignore
  end
end

# Data structure to keep track of requests
$requests = {}
# Function to request content
def request_content(socket, id, offset = 0)
  return if $requests[id] && $requests[id][:offset] > offset
  peer = $requests[id][:peer] if $requests[id]
  peer ||= $peers.to_a.sample
  if ! $requests[id] 
	$requests[id] = { offset: offset, peers: $peers, peer: peer, timestamp: Time.now }
  end
  host, port = peer
  msg = [{PleaseSendContent: {
    id: id,
    length: 4096,
    offset: offset
  }}].to_json
  socket.send(msg, 0, host.to_s, port)
  puts "requesting " + offset.to_s + " from " + host.to_s + ":" + port.to_s

end


                            

# Function to handle content
def handle_content(id, base64, offset, eof, socket, addr)
  Dir.mkdir('downloads') unless Dir.exist?('downloads')
  filename = "downloads/#{id}"
  File.open(filename, 'ab') do |f|
    f.seek(offset)
    f.write(Base64.decode64(base64))
  end
  $requests[id][:timestamp] = Time.now # update timestamp
  if offset + Base64.decode64(base64).size >= eof
    puts "Download of #{id} complete!"
    $requests.delete(id)
  else
    $requests[id][:offset] = offset + 4096
    $requests[id][:peer] = [addr[3], addr[1]]
    request_content(socket, id, offset + 4096)
  end
end





$peer_request_time = Time.now - 20


id = ARGV[0]
if id && $peers.size > 0
  request_content(socket, id)
  id = nil # only request once
end

loop do
  # Check for stalled transfers and retry
  $requests.each do |id, request|
  if Time.now - request[:timestamp] > 1 
	puts "Retrying stalled transfer for #{id}..."
	if Time.now - request[:timestamp] > 10
	  request[:peer] = $peers.to_a.sample
	end
	request_content(socket, id, request[:offset])
  end
  end

  # Request peers periodically
  if Time.now - $peer_request_time > 10 # request peers every 10 seconds
  $peer_request_time = Time.now
  send_request(socket)
  end

  # Set a timeout of 1 second
  if IO.select([socket], nil, nil, 1)
    data, addr = socket.recvfrom(8192)
    begin
      msg = JSON.parse(data, symbolize_names: true)
      if msg.is_a?(Array) && msg.first.is_a?(Hash)
        if msg.first[:PleaseSendPeers]
          # Respond with peers
          send_peers(socket, addr)
        elsif msg.first[:PleaseSendContent]
          # Respond with content
          id = msg.first[:PleaseSendContent][:id]
          offset = msg.first[:PleaseSendContent][:offset]
          length = msg.first[:PleaseSendContent][:length]
          send_content(socket, id, offset, length, addr)
        elsif msg.first[:Peers]
          # Handle incoming peers
          msg.first[:Peers][:peers].each do |peer|
            # Parse host:port pair
            host, port = peer.split(':')
            ip = IPAddr.new(host)
            $peers << [ip, port.to_i]
          end
        elsif msg.first[:Content]
          # Handle content
          id = msg.first[:Content][:id]
          base64 = msg.first[:Content][:base64]
          offset = msg.first[:Content][:offset]
          eof = msg.first[:Content][:eof]
		  handle_content(id, base64, offset, eof, socket, addr)
        end
      end
    rescue JSON::ParserError => e
      puts "Error parsing JSON: #{e.message}"
    end
  end
end
