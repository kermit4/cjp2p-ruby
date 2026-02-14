#!/usr/bin/ruby
require 'socket'
require 'json'
require 'ipaddr'
require 'set'
require 'base64'
require 'fileutils'

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
  filename = "#{id}"
  return if id.include?('/') # security check
  puts "maybe sending #{id}"
  begin
    File.open(filename, 'rb') do |f|
      puts "sending #{id}"
      f.seek(offset)
      data = f.read(length)
      eof = f.size
      if offset >= eof
        return
      end
      encoded_data = Base64.strict_encode64(data)
      msg = [{Content: {
        id: id,
        base64: encoded_data,
        eof: eof,
        offset: offset
      }}].to_json
      socket.send(msg, 0, addr[3], addr[1])
    end
    puts "sent + #{id} #{offset} to #{addr[3]}:#{addr[1]}"
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
  return if not $requests[id]
  return if $requests[id][:offset] > offset
  filename = "incoming/#{id}"
  File.open(filename, 'r+') do |f|
    f.seek(offset)
    f.write(Base64.decode64(base64))
  rescue 
    return
  end
  $requests[id][:timestamp] = Time.now # update timestamp
  if eof and offset + Base64.decode64(base64).size >= eof
    puts "Download of #{id} complete!"
    $requests.delete(id)
    File.rename("incoming/#{id}","#{id}")
  else
    $requests[id][:offset] = offset + 4096
    $requests[id][:peer] = [addr[3], addr[1]]
    request_content(socket, id, offset + 4096)
  end
end



def return_message(socket, addr, msg)
  msg = [{ReturnedMessage: msg}].to_json
  socket.send(msg, 0, addr[3], addr[1])
end


$peer_request_time = Time.now - 20

FileUtils.mkdir_p 'shared/incoming'
Dir.chdir 'shared'

id = ARGV[0]
if id 
  request_content(socket, id)
  filename = "incoming/#{id}"
  File.open(filename, 'w+');
end

loop do
  # Check for stalled transfers and retry
  $requests.each do |id, request|
  if Time.now - request[:timestamp] > 1 
	puts "Retrying stalled transfer for #{id}..."
	request_content(socket, id, request[:offset])
	request_content(socket, id, request[:offset])
	request_content(socket, id, request[:offset])
    request[:peer] = $peers.to_a.sample
	request_content(socket, id, request[:offset])
    request[:peer] = $peers.to_a.sample
	request_content(socket, id, request[:offset])
    request[:peer] = $peers.to_a.sample
	request_content(socket, id, request[:offset])
    request[:peer] = $peers.to_a.sample
	request_content(socket, id, request[:offset])
    $requests[id][:timestamp] = Time.now # update timestamp
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
      $peers << [addr[3], addr[1]]
      msgs = JSON.parse(data, symbolize_names: true)
      if msgs.is_a?(Array) 
        msgs.each do |msg|
          if msg.is_a?(Hash)
            if msg[:PleaseSendPeers]
              # Respond with peers
              send_peers(socket, addr)
            elsif msg[:PleaseSendContent]
              # Respond with content
              id = msg[:PleaseSendContent][:id]
              offset = msg[:PleaseSendContent][:offset]
              length = msg[:PleaseSendContent][:length]
              send_content(socket, id, offset, length, addr)
            elsif msg[:Peers]
              # Handle incoming peers
              msg[:Peers][:peers].each do |peer|
                # Parse host:port pair
                host, port = peer.split(':')
                ip = IPAddr.new(host)
                $peers << [ip, port.to_i]
              end
            elsif msg[:Content]
              # Handle content
              id = msg[:Content][:id]
              base64 = msg[:Content][:base64]
              offset = msg[:Content][:offset]
              eof = msg[:Content][:eof]
              handle_content(id, base64, offset, eof, socket, addr)
            elsif msg[:PleaseReturnThisMessage]
              # Respond with peers
              return_message(socket, addr, msg[:PleaseReturnThisMessage])
            else
              puts "unknown message #{msg}"
            end
          end
        end
      end
    rescue JSON::ParserError => e
      puts "Error parsing JSON: #{e.message} for  #{msg}"
    end
  end
end
