#!/usr/bin/perl
# MNotch generic agent notifier.
#
# For agents without a blocking permission hook (Gemini CLI, etc.). Point
# their notify command at this script. It forwards a lightweight status event
# to MNotch so the session shows up in the notch — no remote approval, just
# awareness + jump.
#
# Usage (from a tool's notify hook):
#   /usr/bin/perl /path/to/mnotch-notify.pl [agent_kind] [title]
# It also reads any JSON on stdin and passes through session_id/cwd if present.

use strict;
use warnings;
use IO::Socket::INET;

my $agent = $ARGV[0] // 'agent';
my $title = $ARGV[1] // 'needs attention';

my $stdin = '';
if (!-t STDIN) { local $/; $stdin = <STDIN> // ''; }
my ($session) = $stdin =~ /"session_id"\s*:\s*"([^"]+)"/;
my ($cwd)     = $stdin =~ /"cwd"\s*:\s*"([^"]+)"/;
$session //= "$agent-$$";
$cwd     //= ($ENV{PWD} // '');

my $home = $ENV{HOME} // '';
my $support = "$home/Library/Application Support/MNotch";
my $token = slurp("$support/agent-token");
my $port  = slurp("$support/agent-port");
exit 0 unless defined $token && defined $port;
$token =~ s/\s+//g; $port =~ s/\s+//g;
exit 0 unless $token ne '' && $port =~ /^\d+$/;

my $sock = IO::Socket::INET->new(
    PeerHost => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 2
) or exit 0;
$sock->autoflush(1);

my $ev = sprintf(
    '{"event":"status","session_id":"%s","cwd":"%s","agent_kind":"%s","title":"%s","term_program":"%s"}',
    esc($session), esc($cwd), esc($agent), esc($title), esc($ENV{TERM_PROGRAM} // '')
);
print $sock qq({"token":"$token","event":$ev}\n);
close $sock;
exit 0;

sub slurp { my ($p) = @_; open my $f, '<', $p or return undef; local $/; my $c = <$f>; close $f; $c }
sub esc { my ($s) = @_; $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g; $s }
