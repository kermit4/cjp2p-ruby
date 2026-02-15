#!/usr/bin/ruby
# vim: set expandtab shiftwidth=2 tabstop=2:
require 'socket'
require 'json'
require 'ipaddr'
require 'set'
require 'base64'
require 'fileutils'

# Use a Set to store unique peers
$peers = Set.new
$sent_packets = {} 
$requests = {}

# Add initial peers
[
  ['148.71.89.128', 24254],
  ['159.69.54.127', 24254]
].each do |host, port|
  $peers << [IPAddr.new(host), port]
end

# Create a UDP socket
$socket = UDPSocket.new
$socket.bind('0.0.0.0', 24257)
# Allow broadcasting
$socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)

# Function to send request for peers
def send_request()
  return if $peers.empty?
  peer = $peers.to_a.sample
  host, port = peer
  #puts "requesting peers" + " from " + host.to_s + ":" + port.to_s
  msg = [{PleaseSendPeers:{}}].to_json
  $socket.send(msg, 0, host.to_s, port)
end

# Function to send $peers
def send_peers(addr)
  peer_list = $peers.map { |peer| "#{peer.first}:#{peer.last}" }
  msg = [{Peers: {peers: peer_list}}].to_json
  $socket.send(msg, 0, addr[3], addr[1])
end

def maybe_they_have_some_send(peers, addr)
      peer_list = peers.map { |peer| "#{peer.first}:#{peer.last}" }
      msg = [{MaybeTheyHaveSome: {
        id: id,
        peers: peer_list
      }}].to_json
      puts "sending #{msg}"
      $socket.send(msg, 0, addr[3], addr[1])
end

def send_content(id, offset, length, addr)
  return if id.include?('/') # security check
  if r=$requests[id] 
    if s=$sent_packets[id] and s[offset] and s[offset][:received]
      f = r[:f]
      length = 4096 if length > 4096
      puts "relaying #{id}"
    else
      maybe_they_have_some_send(r[:peers],addr)
    end
    if rand < 0.01
       maybe_they_have_some_send(r[:peers],addr)
    end
  else
    begin
      f = File.open("#{id}", 'rb')
    rescue Errno::ENOENT
      # file not found, ignore
    end
  end
  if f
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
    $socket.send(msg, 0, addr[3], addr[1])
  end
  puts "sent + #{id} #{offset} to #{addr[3]}:#{addr[1]}"
end

# Function to request content
def request_content(id, offset = 0)
  return if $requests[id] and $requests[id][:offset] > offset
  if $requests[id] and $requests[id][:lastPeer]
    peer = $requests[id][:lastPeer] 
  else
    peer = $peers.to_a.sample 
  end

  host, port = peer
  msg = [{PleaseSendContent: { id: id, length: 4096, offset: offset }}].to_json
  $socket.send(msg, 0, host.to_s, port)
  $sent_packets[id] ||= {}
  $sent_packets[id][offset] ||= {}
  $sent_packets[id][offset][:timestamp] = Time.now 
  #puts "requesting " + offset.to_s + " from " + host.to_s + ":" + port.to_s

end



# Function to handle content
def handle_content_suggestions(m)
  id=m[:id]
  return if not r= $requests[id]
  puts "got content suggestions"
  puts r[:peers]
  puts $requests[id][:peers]
  m[:peers].each do |peer|
    # Parse host:port pair
    host, port = peer.split(':')
    ip = IPAddr.new(host)
    r[:peers]  << [ip, port.to_i]
  end
  puts r[:peers]
  puts $requests[id][:peers]
end
def handle_content(id, base64, offset, eof, addr)

  return if not $requests[id]
  $requests[id][:lastPeer]=[addr[3],addr[1]]
  $requests[id][:peers] << [addr[3], addr[1]]
  filename = "incoming/#{id}"
  $requests[id][:timestamp] = Time.now # update timestamp
  if $sent_packets[id] and $sent_packets[id][offset] and
    ! $sent_packets[id][offset][:received]
    $sent_packets[id][offset][:received] = true
    $requests[id][:f].seek(offset)
    $requests[id][:bytes_complete] += $requests[id][:f].write(Base64.decode64(base64))
    #puts " complete #{$requests[id][:bytes_complete]} at #{offset} out of #{eof}"
    if $requests[id][:bytes_complete] == eof
      puts "Download of #{id} finished!"
      $requests.delete(id)
      $sent_packets.delete(id)
      File.rename("incoming/#{id}","#{id}")
      return
    end
    #else puts "dup? #{offset}"
  end

  #puts "received   #{offset}"
  # Slide the window forward
  $requests[id][:offset] += 4096
  while $sent_packets[id] and $sent_packets[id][$requests[id][:offset]] and $sent_packets[id][$requests[id][:offset]][:received]
    $requests[id][:offset] += 4096
  end
  $requests[id][:offset] = 0 if $requests[id][:offset] > eof
  request_content(id, $requests[id][:offset])

  # Request an extra packet with a certain probability
  if rand < 0.01
    $requests[id][:offset] += 4096
    $requests[id][:offset] =0 if $requests[id][:offset] > eof
    #puts "EXTRA #{$requests[id][:offset]}"
    request_content(id, $requests[id][:offset])
  end
end



def return_message(addr, msg)
  msg = [{ReturnedMessage: msg}].to_json
  $socket.send(msg, 0, addr[3], addr[1])
end


$peer_request_time = Time.now - 20

FileUtils.mkdir_p 'shared/incoming'
Dir.chdir 'shared'

id = ARGV[0]
if id 
  filename = "incoming/#{id}"
  $requests[id] = { offset: 0, peers: Set.new, peer: nil, timestamp: Time.now, f: File.open(filename, 'w+'),bytes_complete:0 }
  request_content(id)
end

loop do
  # Check for stalled transfers and retry
  $requests.each do |id, request|
    if Time.now - request[:timestamp] > 1 
      puts "Retrying stalled transfer for #{id}..."
      request_content(id, request[:offset])
      request_content(id, request[:offset])
      request_content(id, request[:offset])
      $requests[id][:lastPeer] = nil;
      request_content(id, request[:offset])
      $requests[id][:lastPeer] = nil;
      request_content(id, request[:offset])
      $requests[id][:lastPeer] = nil;
      request_content(id, request[:offset])
      $requests[id][:lastPeer] = nil;
      request_content(id, request[:offset])
      $requests[id][:timestamp] = Time.now # update timestamp
    end
  end

  # Request peers periodically
  if Time.now - $peer_request_time > 10 # request peers every 10 seconds
    $peer_request_time = Time.now
    send_request()
  end

  # Set a timeout of 1 second
  if IO.select([$socket], nil, nil, 1)
    data, addr = $socket.recvfrom(8192)
    begin
      $peers << [addr[3], addr[1]]
      msgs = JSON.parse(data, symbolize_names: true)
      if msgs.is_a?(Array) 
        msgs.each do |msg|
          if msg.is_a?(Hash)
            if msg[:PleaseSendPeers]
              # Respond with peers
              send_peers(addr)
            elsif msg[:PleaseSendContent]
              # Respond with content
              id = msg[:PleaseSendContent][:id]
              offset = msg[:PleaseSendContent][:offset]
              length = msg[:PleaseSendContent][:length]
              send_content(id, offset, length, addr)
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
              handle_content(id, base64, offset, eof, addr)
            elsif m = msg[:MaybeTheyHaveSome]
              # Handle content
              handle_content_suggestions(m)
            elsif msg[:PleaseReturnThisMessage]
              # Respond with peers
              return_message(addr, msg[:PleaseReturnThisMessage])
            else
              puts "unknown message #{msg}"
            end
          end
        end
      end
    rescue JSON::ParserError => e
      puts "Error parsing JSON: #{e.message} for  #{msgs}"
    end
  end
end
