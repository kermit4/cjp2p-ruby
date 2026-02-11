#!/usr/bin/ruby
require 'socket'
require 'json'
require 'ipaddr'
require 'set'

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

loop do
  # Send request for peers occasionally
  send_request(socket, peers)

  # Set a timeout of 1 second
  if IO.select([socket], nil, nil, 1)
    data, addr = socket.recvfrom(1024)
    begin
      msg = JSON.parse(data, symbolize_names: true)
      if msg.is_a?(Array) && msg.first.is_a?(Hash) && msg.first[:Peers]
        msg.first[:Peers][:peers].each do |peer|
          # Parse host:port pair
          host, port = peer.split(':')
          ip = IPAddr.new(host)
          peers << [ip, port.to_i]
        end
      end
    rescue JSON::ParserError => e
      puts "Error parsing JSON: #{e.message}"
    end
  end
end

