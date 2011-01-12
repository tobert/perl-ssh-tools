package DshPerlHostLoop;

###########################################################################
#                                                                         #
# Cluster Tools: DshPerlHostLoop.pm                                       #
# Copyright 2007-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

use strict;
use warnings;
use Carp;
use File::Basename;
use Data::Dumper;
use IPC::Open3;
use IO::Select;
use IO::Handle;
use base 'Exporter';

BEGIN {
    use vars qw( @opt_filter_excl @opt_filter_incl );
}

our $ssh_options = "-o 'BatchMode yes' -o 'StrictHostKeyChecking no' -o 'ConnectTimeout 10'";
our $tag_output;
our %ssh2_connections;
our $verbose;
our $machinelist;

# Most shops have a noisy /etc/issue.net. This reads the local issue.net
# and removes any lines matching it from the output from ssh.
my @issue = read_issue();
my $issue_len = length(join("\n", @issue));

our @EXPORT = qw(func_loop ssh scp hostlist reap $ssh_options tag_output @opt_filter_excl @opt_filter_incl verbose);

=head1 NAME

DshPerlHostLoop - loops for running ssh commands across large clusters in parallel

=head1 SYNOPSIS

 use FindBin qw($Bin);
 require "$Bin/DshPerlHostLoop.pm";

 func_loop( sub { system( "ssh $_[1] uname -a" ); } );

=head1 GLOBAL SWITCHES

A few global CLI switches are implemented in this module in a BEGIN block.

 --incl - a perl regular expression that filters out non-matching hostnames
 --excl - a perl regular expression that filters matched hostnames out of the list
 -t     - tag output with the hostname
 -v     - verbose
 -m     - specify a file with a list of hosts to use (default is ~/.dsh/machines.list)

--excl RE's are run before --incl RE's.

=cut

=head1 FUNCTIONS

=over 4

=item func_loop()

Execute a callback in parallel for each host.   The first argument passed to each callback will be the hostname.

 # hello, cruel world
 func_loop( sub { print "$@\n"; } );

=cut

sub func_loop {
	my $f = shift;

	if ( ref($f) ne 'CODE' ) {
		confess "Argument to DshPerlHostLoop must be a subroutine/closure.";
	}

	my %pids;
	foreach my $hostname ( hostlist() ) {
		my $pid = fork();
		if ( $pid ) {
			$pids{$hostname} = $pid;
			next;
		}
		else {
			eval { $0 = "$0 -- $hostname"; };
			my @out = eval { $f->( $hostname ); };
			if ( $@ ) {
				confess $@;
			}

			exit 0;
		}
	}

	reap( \%pids );
}

=item read_issue()

Read /etc/issue.net or if that doesn't exist, /etc/issue.   This is used to filter out
issues from remote systems to keep your output readable.

Returns an array of chomped lines.

=cut

sub read_issue {
    my @issue;
    my $fh;
    if ( -r '/etc/issue.net' ) {
        open( my $fh, "< /etc/issue.net" ) or $fh = undef;
    }
    elsif ( -r '/etc/issue' ) {
        open( my $fh, "< /etc/issue" ) or $fh = undef;
    }
    if ( $fh ) {
        while ( my $line = <$fh> ) {
            chomp $line;
            push @issue, $line;
        }
        close $fh;
    }
    return @issue;
}

=item ssh()

Run a command over ssh.

 func_loop(sub {
     my $host = shift;
     ssh( $host, 'ps -ef' );
 });

=item scp()

scp a file.

 my($local_file, $remote_file) = ("/etc/hosts", "/etc/hosts");
 func_loop(sub {
     my $host = shift;
     scp( $local_file, "$host:$remote_file" );
 });

=item scmd()

The actual function behind ssh/scp.

 sub ssh { scmd('/usr/bin/ssh', @_) }
 sub scp { scmd('/usr/bin/scp', '-v', @_) }

=cut

# archaic & insecure but fast and convenient
# in other words, don't let untrusted people sudo this!!
sub ssh { scmd('/usr/bin/ssh', @_) }
sub scp { scmd('/usr/bin/scp', '-v', @_) }
sub scmd {
    my $scmd = shift;

    my @output;
    my( $in, $out, $err ) = (IO::Handle->new, IO::Handle->new, IO::Handle->new);
    my $pid = open3( $in, $out, $err, "$scmd $ssh_options @_" );

    if ( $verbose ) {
        print STDERR "Command($$): $scmd $ssh_options @_\n";
    }

    my $select = IO::Select->new( $out, $err );
    my $ofd = fileno($out);
    my $efd = fileno($err);

    my %eofs;

    my $bytes = 0;
    SELECT: while ( my @ready = $select->can_read(10) ) {
        READY: foreach my $r ( @ready ) {
            my $rfd = fileno($r);

            if ( exists($eofs{$rfd}) ) {
                $select->remove($rfd);
                next SELECT;
            }
            elsif ( $rfd == $ofd ) {
                my $line = <$out>;
                chomp $line if ( $line );
                $bytes += length($line) if ( $line );
                push @output, $line if ( $line );

                $eofs{$rfd} = 1 if ( eof($out) );
            }
            elsif ( $rfd == $efd ) {
                my $line = <$err>;
                chomp $line if ( $line );
                # don't look for issue.net matches after its byte size has past
                unless ( !$line or ($bytes < $issue_len and grep { $_ eq $line } @issue) ) {
                    $bytes += length($line) if ( $line );
                    push @output, $line;
                }
                $eofs{$rfd} = 1 if ( eof($err) );
            }
            else {
                warn "Got read error on $rfd ...";
            }

        }
    }

    if ( $bytes == 0 ) {
        print STDERR "Got zero bytes from command: $scmd @_\n";
    }

    waitpid( $pid, 0 );
    if ( $? != 0 ) {
        print STDERR "Got non-zero exit status from command: $scmd @_\n";
    }

    return @output;
}

=item hostlist()

Returns an array of hosts to be accessed.  This reads the hostname list (-m $file or default ~/.dsh/machines.list)
then filters it based on --excl and --incl regular expressions.  

=cut

sub hostlist {
	my @hostlist;

    if (not defined $machinelist or length $machinelist == 0) {
        $machinelist = "$ENV{HOME}/.dsh/machines.list";
    }

    open( my $fh, "< $machinelist")
        or die "Could not open machine list file '$machinelist' for reading: $!";

    HOST: while ( my $hostname = <$fh> ) {
        chomp $hostname;
        $hostname =~ s/\s//g;
        next unless ( length $hostname );
        next if ( $hostname =~ /^#/ );

        FILTER_EX: foreach my $excl ( @opt_filter_excl ) {
		    if ( $hostname =~ /$excl/ ) {
			    print "DshPerlHostLoop: Skipping $hostname because it matched filter $excl.\n" if ( $verbose );
			    next HOST;
		    }
        }
        FILTER_IN: foreach my $incl ( @opt_filter_incl ) {
		    if ( $hostname !~ /$incl/i ) {
			    print "DshPerlHostLoop: Skipping $hostname because it didn't match filter $incl.\n" if ( $verbose );
			    next HOST;
		    }
        }

		push @hostlist, $hostname;
	}

    close $fh;

	return @hostlist;
}

=item reap()

Reap child processes from the forkbomb. The hash is { $hostname => $pid }.

 reap(\%pids);

=cut

sub reap {
	my $pids = shift;
	foreach my $host ( keys %$pids ) {
		waitpid( $pids->{$host}, 0 );
		delete $pids->{$host};
	}
}

=item tag_output()

Toggle/get whether or not output should be prefixed with the hostname.

=cut

sub tag_output {
	if ( @_ == 1 ) {
		$tag_output = shift;
	}
	return $tag_output;
}

=item verbose()

Toggle/get whether or not to be verbose.

=cut

sub verbose {
    if ( @_ == 1 ) {
        $verbose = shift;
    }
    return $verbose;
}

# nasty brute force argument stealing :)
# BEGIN makes sure this runs before Getopt::* as long as that module
# isn't also called from within a BEGIN block
BEGIN {
	my @to_kill;

	for ( my $i=0; $i<@main::ARGV; $i++ ) {
        # skip anything after -- by itself, just like GNU convention
        # don't remove it though, so GetOptions can have a whack at processing
        last if ( $main::ARGV[$i] eq '--' );

		if ( $main::ARGV[$i] eq '--incl' || $main::ARGV[$i] eq '-i' ) {
			push @to_kill, $i, $i+1;
			my $f = $main::ARGV[$i+1];
			push @opt_filter_incl, qr/$f/;
		}
		if ( $main::ARGV[$i] eq '--excl' ) {
			push @to_kill, $i, $i+1;
			my $f = $main::ARGV[$i+1];
			push @opt_filter_excl, qr/$f/;
		}
		if ( $main::ARGV[$i] eq '-m' ) {
			push @to_kill, $i, $i+1;
            $machinelist = $main::ARGV[$i+1];
		}
		if ( $main::ARGV[$i] eq '-t' ) {
			push @to_kill, $i;
			$tag_output = 1;
		}
		if ( $main::ARGV[$i] eq '-v' ) {
			push @to_kill, $i;
            $verbose = 1;
		}
	}

	# do them in reverse order
	foreach my $idx ( reverse sort @to_kill ) {
		delete $main::ARGV[$idx];
	}
}

1;

# vim: et ts=4 sw=4 ai smarttab

__END__

=back

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2011 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
