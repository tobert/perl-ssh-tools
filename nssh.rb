#!/usr/bin/ruby
# intentionally not using /bin/env - this script always works w/ system ruby
#
###########################################################################
#                                                                         #
# Cluster Tools: nssh.rb                                                  #
# Copyright 2011-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################
#
# This script does minimal arg parsing to filter out SSH arguments to
# be mostly compatible with plain SSH command line syntax. It's not
# 100% but good enough.
#
# usage: nssh [-1246AaCfgKkMNnqsTtVvXxY] [-b bind_address] [-c cipher_spec]
#           [-D [bind_address:]port] [-e escape_char] [-F configfile]
#           [-i identity_file] [-L [bind_address:]port:host:hostport]
#           [-l login_name] [-m mac_spec] [-O ctl_cmd] [-o option] [-p port]
#           [-R [bind_address:]port:host:hostport] [-S ctl_path]
#           [-w local_tun[:remote_tun]] [user@]hostname
#
# nssh-specific arguments:
#   --list <machine_list>   A machine list is a dsh-style ~/.dsh/machines.$listname.
#   --comment "[COMMENT]"   comment to place after the hostname in the screen title
#  
# I ported this to ruby as an exercise, so there may be things that aren't proper.
#

require 'resolv'

class NamedSSH
  attr_reader :dsh_config_dir
  attr_reader :dsh_config_file
  attr_reader :dsh_list
  attr_reader :nssh_last_file
  attr_reader :ssh_args
  attr_accessor :hostname
  attr_accessor :comment

  def initialize(options = {})
    @ssh_args = options[:ssh_args] || Array.new
    @dsh_list = options[:dsh_list] || "machines.list"
    @comment  = options[:comment]  || ""

    @dsh_config_dir  = options[:dsh_config_dir]
    @dsh_config_file = File.join(@dsh_config_dir, @dsh_list)
    @nssh_last_file  = options[:nssh_last_file]
    @hostname        = options[:hostname]

    unless @hostname != nil and @hostname.length > 3
      raise "Invalid hostname '#@hostname'."
    end
  end

  # most of the arg parsers looked painful to do what this does;
  # it needs to stash & ignore SSH options, while parsing out --list
  # and grab the hostname
  def self.parse_options
    ssh_args = Array.new
    dsh_list = nil
    hostname = nil
    comment  = ""

    # manual argument parsing - be intelligent about perserving ssh
    # options while adding custom options for nssh
    idx=0
    loop do
      break if idx == ARGV.size

      #puts "Arg #{idx}: #{ARGV[idx]}"

      # ssh switches
      if ARGV[idx].match(/^-[1246AaCfgKkMNnqsTtVvXxY]$/)
        ssh_args << ARGV[idx]
        #puts "ssh switch #{ssh_args[-1]}"

      # ssh options that take a value
      elsif ARGV[idx].match(/^-[bcDeFiLlmOopRSw]$/)
        ssh_args << ARGV[idx]
        idx+=1
        # force quoting - it should never hurt and makes stuff like -o options work correctly
        ssh_args << ARGV[idx]
        #puts "ssh args #{ssh_args[-2]} #{ssh_args[-1]}"

      # allow specification of a .dsh list in my style where --list foobar resolves to
      # ~/.dsh/machines.foobar to use with "nssh --list foobar next"
      elsif ARGV[idx].match(/^--list/)
        idx+=1
        dsh_list = "machines." << ARGV[idx]
        #puts "dsh list: #{dsh_list}"
        
      # --comment
      elsif ARGV[idx].match(/^--comment/)
        idx+=1
        comment = ARGV[idx]

      # --user, e.g. nssh next --user root
      elsif ARGV[idx].match(/^--user/)
        idx+=1
        ssh_args << '-o' << "User #{ARGV[idx]}"

      # user@hostname is a definite match
      # split it and use -u instead because hostname needs to be standalone
      elsif ARGV[idx].match(/^\w+@[-\.\w]+$/)
        user, hostname = ARGV[idx].split '@'
        ssh_args << '-o' << "User #{user}"
        #puts "user@hostname: user: #{user}, hostname: #{hostname}"

      # a bare, uncaptured argument is likely the hostname
      else
        hostname = ARGV[idx]
        #puts "hostname: #{hostname}"
      end

      idx+=1
    end

    return {
      :ssh_args => ssh_args,
      :dsh_list => dsh_list,
      :hostname => hostname,
      :comment  => comment
    }
  end

  def parse_host(host)
    return nil, nil if host == nil
    host.chomp!
    return nil, nil if host == ''

    h, comment = host.split /\s*#\s*/, 2

    return h, comment
  end

  # read the last host from "nssh next" iteration from a file
  def read_last()
    host = nil
    comment = nil

    if File.exists?(@nssh_last_file)
      File.open(@nssh_last_file, 'r') do |f|
        host, comment = parse_host f.gets
      end
    end

    return host, comment
  end

  # save the last host for "nssh next" iteration
  def save_last
    File.open(@nssh_last_file, 'w') do |f|
      f.puts @hostname
    end
  end

  # read the dsh machines file and return the next host in the list
  # after whatever was in the @nssh_last_file
  def read_next
    last, comment = read_last()

    unless File.exists?(@dsh_config_file)
      raise "#@dsh_config_file does not exist on the filesystem. --list #@dsh_list is not valid."
    end

    File.open(@dsh_config_file, 'r') do |f|
      until f.eof?
        candidate, comment = parse_host f.gets

        # last host is not defined, return first in file
        if last.nil?
          return candidate, comment
        end

        if candidate == last
          if f.eof?
            raise "Reached end of #@dsh_config_file. There is no next host!"
          else
            while not f.eof?
              candidate, comment = parse_host f.gets
              if candidate != nil
                return candidate, comment
              end
            end
          end
        end
      end
    end
  end
end

# use class method to parse ARGV
options = NamedSSH.parse_options

nssh = NamedSSH.new(
  :dsh_config_dir => File.join(ENV['HOME'], ".dsh"),
  :nssh_last_file => File.join(ENV['HOME'], '.nssh-last'),
  :hostname       => options[:hostname],
  :ssh_args       => options[:ssh_args],
  :dsh_list       => options[:dsh_list],
  :comment        => options[:comment]
)

# reset the position in the machine list to the top
if nssh.hostname == "reset"
  File.unlink(nssh.nssh_last_file)
  exit
end

# choose the next host in the machine list, great for firing  up
# a ton of screen windows in a row in an already-running screen
# If I'm logging into a whole cluster in an existing screen session, I'll load
# "nssh next --list $cluster" into my clipboard then ...
# ctrl-a n, <paste>, <enter>, ctrl-a n <paste> <enter>, ...
# (my screenrc spawns with 256 open & ready shells)
if nssh.hostname == "next"
  nssh.hostname, nssh.comment = nssh.read_next
  nssh.save_last
end

# set the terminal title in GNU Screen
if nssh.comment != nil and nssh.comment != "" then
  puts "\033k#{nssh.hostname} [#{nssh.comment}]\033\\"
else
  puts "\033k#{nssh.hostname}\033\\"
end

# set an environment variable to the selected hostname to
# pass through SSH. LC_* is accepted by default in most ssh servers
# this is useful for setting a PS1 with a meaningful CNAME on the remote
# host via .profile (esp handy for EC2 boxen)
# Note: this is really just a proof-of-concept and will not work in
# hardened environments.
# e.g.
# ps1host=$(hostname)
# [ -n "$LC_UI_HOSTNAME" ] && ps1host=$LC_UI_HOSTNAME
# if [[ ${EUID} == 0 ]] ; then
#   PS1="\\[\\033[01;31m\\]$ps1host\\[\\033[01;34m\\] \\W \\$\\[\\033[00m\\] "
# else   
#   PS1="\\[\\033[01;32m\\]\\u@$ps1host\\[\\033[01;34m\\] \\w \\$\\[\\033[00m\\] "
# fi
ENV['LC_UI_HOSTNAME'] = nssh.hostname

# resolve hostnames to IP then back to the IP's name because
# I don't see where resolv lets you just get the CNAME
# this helps for stuff where we use CNAME's to point at e.g. EC2 hosts
# to switch to the EC2 name before ssh'ing but still set all the display
# stuff to the human hostname
#
# I use this to make ssh match config entries in ~/.ssh/config which is generated
# based on the EC2 instance name. This saves me having to do backflips to provide
# extra aliases in ssh_config while still letting me nssh to the CNAME's.
resolver = Resolv.new
addr = resolver.getaddress nssh.hostname
realname = resolver.getname addr

# I didn't see a more elegant way to do this ...
def exec_no_sh(*args)
  arglist = Array.new
  args.each do |arg|
    if arg.class == Array.new.class
      arg.each do |item|
        arglist << item
      end
    else
      arglist << arg
    end
  end

  Kernel.exec *arglist
end

# run SSH
exec_no_sh "ssh", nssh.ssh_args, realname

# vim: et ts=2 sw=2 ai smarttab
#
# This software is copyright (c) 2011-2011 by Al Tobey.
#
# This is free software; you can redistribute it and/or modify it under the terms
# of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
# version 2.0 is GPL compatible by itself, hence there is no benefit to having an
# Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

