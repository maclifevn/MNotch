#!/usr/bin/perl
# Nonblocking status notifier; never parses JSON with regex or edits agent state.
use strict;
use warnings;
use IO::Socket::INET;
use JSON::PP qw(decode_json encode_json);
$SIG{PIPE} = 'IGNORE';
$SIG{ALRM} = sub { exit 0 };
alarm 2;
my $agent = $ARGV[0] // 'agent';
my $title = $ARGV[1] // 'needs attention';
my $stdin = '';
if (!-t STDIN) {
    while (1) {
        my $chunk;
        my $n = sysread(STDIN, $chunk, 65536);
        exit 0 unless defined $n;
        last if $n == 0;
        $stdin .= $chunk;
        exit 0 if length($stdin) > 900000;
    }
}
alarm 5;
my $payload = eval { decode_json($stdin) };
$payload = {} unless ref($payload) eq 'HASH';
my $session = $payload->{session_id};
my $cwd = $payload->{cwd};
$session = "$agent-$$" if !defined($session) || ref($session);
$cwd = $ENV{PWD} // '' if !defined($cwd) || ref($cwd);
my $support = $ENV{MNOTCH_SUPPORT_DIRECTORY}
    // (($ENV{HOME} // '') . '/Library/Application Support/MNotch');
my $token = slurp("$support/agent-token");
my $port = slurp("$support/agent-port");
exit 0 unless defined $token && defined $port;
$token =~ s/\s+//g; $port =~ s/\s+//g;
exit 0 unless length($token) > 0 && $port =~ /^\d+$/ && $port > 0 && $port <= 65535;
my $sock = IO::Socket::INET->new(
    PeerHost => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 2
) or exit 0;
$sock->autoflush(1);
my $envelope = encode_json({ token => $token, event => {
    event => 'status', session_id => $session, cwd => $cwd, agent_kind => $agent,
    title => $title, term_program => $ENV{TERM_PROGRAM} // ''
}}) . "\n";
print $sock $envelope if length($envelope) <= 1000000;
close $sock;
exit 0;
sub slurp {
    my ($path) = @_;
    open my $file, '<', $path or return undef;
    my $content;
    read($file, $content, 4096);
    close $file;
    return $content;
}
