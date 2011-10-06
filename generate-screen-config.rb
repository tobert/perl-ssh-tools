#!/usr/bin/ruby
# intentionally not using /bin/env - this script always works w/ system ruby
#
###########################################################################
#                                                                         #
# Cluster Tools: generate-screen-config.rb                                #
# Copyright 2011-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################
#
# Auto-generate the bulk of my screenrc from machine lists.
# 

require 'resolv'

lists = [
  "cluster1",
  "cluster2",
  "cluster3",
  "cluster4",
  "cluster5",
]

resolver = Resolv.new
top = []
gen = []
bottom = []
seen = {
  :highest => 0,
  :begin   => false,
  :end     => false
}

File.foreach(File.join(ENV['HOME'], ".screenrc-main")) do |line|
  if line =~ /## BEGIN GENERATED CONFIG ##/ then
    seen[:begin] = true
    next
  end
    
  if line =~ /## END GENERATED CONFIG ##/ then
    seen[:end] = true
    next
  end

  next if seen[:begin] and not seen[:end]

  if line =~ /^screen.*\s(\d+)$/ then
    num = $1.to_i
    if num > seen[:highest] then
      seen[:highest] = num
    end
  end

  if seen[:end]
    bottom.push line
  else
    top.push line
  end
end

count = seen[:highest] + 10

lists.each do |listname|
  file = "machines.#{listname}"

  while count % 10 != 0 do
    gen.push "screen -t \"localhost\" #{count}"
    gen.push "stuff \". ~/.profile\\015\""
    count+=1
  end

  gen.push "screen -t \"CLUSTER: #{listname}\" #{count}"
  gen.push "stuff \". ~/.profile\\015cl-netstat.pl --list #{listname}\""
  count+=1

  File.open(File.join(ENV['HOME'], ".dsh", file), "r") do |f|
    f.each_line do |host|
      host.chomp!
      host, comment = host.split /\s*#\s*/, 2
      host = host[/\S+/]

      next if host == nil or host == ''

      match = host.match(/^(#?)(\S+)/)
      if match then
        if match[1] != nil and match[1].to_s == "#"
          host = match[2].to_s
          comment = "[DOWN] #{comment}"
        end
      end

      next if seen.has_key?(host)
      seen[host] = true
 
      gen.push "screen -t \"#{host}\" #{count}"
      gen.push "stuff \". ~/.profile\\015nssh --comment '#{comment}' #{host}\\015dstat -lrvn 60\\015\""
      count+=1
    end
  end
end

File.open(File.join(ENV['HOME'], ".screenrc-main"), "w") do |f|
  top.each do |line|
    f.puts line
  end

  f.puts "## BEGIN GENERATED CONFIG ##"
  gen.each do |line|
    f.puts line
  end
  f.puts "## END GENERATED CONFIG ##"

  bottom.each do |line|
    f.puts line
  end
end

# vim: et ts=2 sw=2 ai smarttab
#
# This software is copyright (c) 2011-2011 by Al Tobey.
#
# This is free software; you can redistribute it and/or modify it under the terms
# of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
# version 2.0 is GPL compatible by itself, hence there is no benefit to having an
# Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.
#

