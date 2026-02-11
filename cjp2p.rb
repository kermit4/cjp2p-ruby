#!/usr/bin/ruby
# vim: set expandtab shiftwidth=2
require 'socket'
require 'json'
require 'ipaddr'
require 'set'
require 'base64'

# Use a Set to store unique peers
peers = Set.new

# Add initial peers
[
  ['148.71.89.128', 24254],
  ['159.69.54.127', 24254]
].each do |host, port|
  peers << [IPAddr.new(host), port]
end

# Create a UDP socket
socket = UDPSocket.new
socket.bind('0.0.0.0', 24257)
# Allow broadcasting
socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)

puts "Listening on UDP port 24257..."

# Function to send request for peers
def send_request(socket, peers)
  return if peers.empty?
  peer = peers.to_a.sample
  host, port = peer
  msg = [{PleaseSendPeers:{}}].to_json
  socket.send(msg, 0, host.to_s, port)
end

# Function to send peers
def send_peers(socket, peers, addr)
  peer_list = peers.map { |peer| "#{peer.first}:#{peer.last}" }
  msg = [{Peers: {peers: peer_list}}].to_json
  socket.send(msg, 0, addr[3], addr[1])
end

                          
# Function to send content
def send_content(socket, id, offset, length, addr)
  filename = "shared/#{id}"
  return if id.include?('/') # security check
  begin
    File.open(filename, 'rb') do |f|
      f.seek(offset)
      data = f.read(length)
      file_size = f.size
      encoded_data = Base64.strict_encode64(data).strip
      msg = [{Content: {
        id: id,
        base64: encoded_data,
        eof: file_size,
        offset: offset
      }}].to_json
      socket.send(msg, 0, addr[3], addr[1])
	  puts "sent " + offset.to_s
    end
  rescue Errno::ENOENT
    # file not found, ignore
  end
end


loop do
  # Send request for peers occasionally
  send_request(socket, peers)

  # Set a timeout of 1 second
  if IO.select([socket], nil, nil, 1)
    data, addr = socket.recvfrom(1024)
    begin
      msg = JSON.parse(data, symbolize_names: true)
      if msg.is_a?(Array) && msg.first.is_a?(Hash)
        if msg.first[:PleaseSendPeers]
          # Respond with peers
          send_peers(socket, peers, addr)
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
            peers << [ip, port.to_i]
          end
        end
      end
    rescue JSON::ParserError => e
      puts "Error parsing JSON: #{e.message}"
    end
  end
end

