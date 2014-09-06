#!/usr/bin/perl -w
# check_ica_servers.pl 
# 2008/08/11 bschmidt (info@netways.de)
# based on ...
#
# $Id: 6ea0c83eb7e63da1045a5a2646ebba3204d1f021 $
# $Log$
# Revision 1.1  2005/01/25 09:05:53  stanleyhopcroft
# New plugin to check Citrix Metaframe XP "Program Neighbourhood"
#
# Revision 1.1  2005-01-25 16:50:30+11  anwsmh
# Initial revision
#

use strict ;
use POSIX qw(SIGALRM);

use Getopt::Long;

use utils qw($TIMEOUT %ERRORS &print_revision &support);
use LWP 5.65 ;
use XML::Parser ;

use threads ;
use Thread::Queue;

my $PROGNAME = 'check_ica_servers.pl' ;
use vars qw(
$verbose
$xml_debug
$pn_server
$pub_app
$app_servers
$server_farm
$usage
$warning
$critical
$maximum
$max_requests
$timeout
) ;

Getopt::Long::Configure('bundling', 'no_ignore_case') ;
GetOptions (
        "V|version"			=> \&version,
        "A|published_app:s"	=> \$pub_app,
        "h|help"			=> \&help,
        'usage|?'			=> \&usage,
        "F|server_farm=s"	=> \$server_farm,
        "P|pn_server=s"		=> \$pn_server,
        "w|warning=s"		=> \$warning,
        "c|critical=s"		=> \$critical,
        "m|maximum=i"		=> \$maximum,
        "M|max_requests=i"	=> \$max_requests,
        "t|timeout=i"		=> \$timeout,
        "v|verbose=i"		=> \$verbose,
        #"d|dry_run"		=> \$dryrun,
        "x|xml_debug"		=> \$xml_debug,
) ;

$pn_server		|| do  {
	print "Name or IP Address of _one_ Program Neighbourhood server is required.\n" ;
	&print_usage ;
	exit $ERRORS{UNKNOWN} ;
} ;

$pub_app		||= 'Word 2003' ;
$pub_app =~ s/["']//g ;
my @pubapp_encoded = map { my $x = $_ ; $x =~ s/(\W)/'&#' . ord($1) . ';'/eg; $x } ($pub_app) ;
my $pubapp_enc = shift @pubapp_encoded ;

if (!defined $warning) {
	$warning = 1;
}

if (!defined $critical) {
	$critical = 0;
}

if (!defined $timeout) {
	# max seconds to run
	$timeout = 60;
}

if (!defined $max_requests) {
	# max 10 requests per sec
	$max_requests = $timeout*10;
}

if (!defined $verbose) {
	$verbose = 0;
}

$server_farm		|| do {
	print "Name of Citrix Metaframe XP server farm is required.\n" ;
	&print_usage ;
	exit $ERRORS{UNKNOWN} ;
} ;

$maximum			|| do {
	print "The maximum number of ICA servers that could offer the service (expected servers) is required.\n" ;
	&print_usage ;
	exit $ERRORS{UNKNOWN} ;
} ;

my %xml_tag = () ;
my @tag_stack = () ;

my $xml_p = new XML::Parser(Handlers => {Start => \&handle_start,
					 End   => sub { pop @tag_stack },
					 Char  => \&handle_char}) ;

# values required by Metaframe XP that don't appear to matter too much

my $client_host		= 'Nagios server (http://www.Nagios.ORG)' ;
my $user_name		= 'nagios' ;
my $domain			= 'Nagios_Uber_Alles' ;

# end values  required by Metaframe XP

my $nilpotent_req	= <<'EOR' ;
<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd"><NFuseProtocol version="1.1">
  <RequestProtocolInfo>
    <ServerAddress addresstype="dns-port" />
  </RequestProtocolInfo>
</NFuseProtocol>
EOR

my $server_farm_req	= <<'EOR' ;
<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
  <RequestServerFarmData>
    <Nil />
  </RequestServerFarmData>
</NFuseProtocol>
EOR

my $spec_server_farm_req = <<EOR ;
<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
  <RequestAddress>
    <Name>
      <UnspecifiedName>$server_farm*</UnspecifiedName>
    </Name>
    <ClientName>$client_host</ClientName>
    <ClientAddress addresstype="dns-port" />
    <ServerAddress addresstype="dns-port" />
    <Flags />
    <Credentials>
      <UserName>$user_name</UserName>
      <Domain>$domain</Domain>
    </Credentials>
  </RequestAddress>
</NFuseProtocol>
EOR

my $app_req		= <<EOR ;
<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
  <RequestAddress>
    <Name>
      <UnspecifiedName>PUBLISHED_APP_ENCODED</UnspecifiedName>
    </Name>
    <ClientName>Nagios_Service_Check</ClientName>
    <ClientAddress addresstype="dns-port"/>
    <ServerAddress addresstype="dns-port" />
    <Flags />
    <Credentials>
      <UserName>$PROGNAME</UserName>
      <Domain>$domain</Domain>
    </Credentials>
  </RequestAddress>
</NFuseProtocol>
EOR

my $ua = LWP::UserAgent->new ;
my $req = HTTP::Request->new('POST', "http://$pn_server/scripts/WPnBr.dll") ;
   $req->content_type('text/xml') ;

my $svr ;

my $error_tag_cr = sub { ! exists($xml_tag{ErrorId}) } ;

my @app_reqs = (
	# { Content => url,				Ok => ok_condition,				Seq => \d+ }

	{ Content => $nilpotent_req,	Ok => $error_tag_cr,			Seq => 0 }, 
	{ Content => $server_farm_req,	Ok => sub {
							! exists($xml_tag{ErrorId})			&&
							exists( $xml_tag{ServerFarmName})	&&
							defined($xml_tag{ServerFarmName})	&&
							$xml_tag{ServerFarmName} eq  $server_farm
									},								Seq => 2 },
	{ Content => $nilpotent_req,	Ok => $error_tag_cr,			Seq => 4 },
	{ Content => $spec_server_farm_req,	Ok => sub {
							! exists($xml_tag{ErrorId})			&&
							exists( $xml_tag{ServerAddress})	&&
							defined($xml_tag{ServerAddress})	&&
							$xml_tag{ServerAddress} =~ /\d+\.\d+\.\d+\.\d+:\d+/
									},								Seq => 6 },
	{ Content => $nilpotent_req,	Ok => $error_tag_cr,			Seq => 8 },
	{ Content => $app_req,			Ok => sub {
							! exists($xml_tag{ErrorId})			&&
							exists( $xml_tag{ServerAddress})	&&
							defined($xml_tag{ServerAddress})	&&
							(($svr) = split(/:/, $xml_tag{ServerAddress})) &&
							defined($svr)						&&
							$svr #scalar(grep $_ eq $svr, @app_servers)
									},								Seq => 10 }
) ;

my %app_loc_servers ;
my %app_req_thrs ;
my $count = 0 ;

my $requests = 0 ;

my $DataQueue = Thread::Queue->new;

# set up alarmhandler
($verbose	>= 2)	&& print STDERR "set timeout to $timeout seconds.\n";
alarm $timeout;
$SIG{ALRM} = \&my_alarm;


#########   lets start getting data   #############

while ( $requests < $maximum ) {
	# create as many threads as we expect results

	$requests++ ;
	$app_req_thrs{$requests} = threads->new(\&do_app_request);
}

while ( $count < $maximum ) {

	$count = scalar keys %app_loc_servers ;
	
	($verbose	>= 4)		&& print STDERR "Requests: $requests, Unique Answers: $count.";

	# gather results (this waits till data is in the queue - a thread give an result)
	my $svr = $DataQueue->dequeue ; 

	($verbose	>= 4)		&& print STDERR " Server: $svr answered ";
	if (defined $app_loc_servers{$svr}) {
		$app_loc_servers{$svr}++ ;
		($verbose	>= 4)	&& print STDERR "$app_loc_servers{$svr}";
	} else {
		$app_loc_servers{$svr} = 1;
		($verbose	>= 4)	&& print STDERR "1";
	}
	($verbose	>= 4)		&& print STDERR " times.";
	($verbose	>= 4)		&& print STDERR "\n";

	if ( $requests >= $max_requests ) {
		&my_exit ;
	}
	if ( $count < $maximum ) {
		# and keep the threads to ask as many as we expect results
		$requests++ ;
		$app_req_thrs{$requests} = threads->new(\&do_app_request, $requests);
	}
}

# no timeout, no error, we will exit cleanly
&my_exit ;

sub do_app_request {

	if ($verbose < 10) {
		# do request

		my $app_req_tmp = $app_reqs[5]{Content} ;
		$app_reqs[5]{Content} =~ s/PUBLISHED_APP_ENCODED/$pubapp_enc/ ;
		
		foreach (@app_reqs) {
		
			$req->content($_->{Content}) ;
		
			($verbose	>= 4)		&& print STDERR "App: $pub_app Seq: $_->{Seq}\n", $req->as_string, "\n" ;
		
			# send request, wait for response
			my $resp = $ua->request($req) ;
		
			($verbose	>= 4)		&& print STDERR "App: $pub_app Seq: ", $_->{Seq} + 1, "\n", $resp->as_string, "\n" ;
		
			$resp->is_error	&& do {
				my $err = $resp->as_string ;
				$err =~ s/\n//g ;
				&my_exit(qq(Failed. HTTP error finding $pub_app at seq $_->{Seq}: "$err")) ;
			} ;
			my $xml = $resp->content ;
		
			my $xml_disp ;
			   ($xml_disp = $xml) =~ s/\n//g ;
			   $xml_disp =~ s/ \s+/ /g ;
		
			&my_exit($resp->as_string)
			unless $xml ;
		
			my ($xml_ok, $whine) = &valid_xml($xml_p, $xml) ;
		
			$xml_ok			|| &my_exit(qq(Failed. Bad XML finding $pub_app at eq $_->{Seq} in "$xml_disp".)) ;
		
			&{$_->{Ok}}		|| &my_exit(qq(Failed. \"\&\$_->{Ok}\" false finding $pub_app at seq $_->{Seq} in "$xml_disp".)) ;
		
								# Ugly but alternative is $_->{Ok}->().
								# eval $_->{Ok} where $_->{Ok} is an
								# expression returning a bool is possible. but
								# sub { } prevent recompilation.
		
		}
		
		$app_reqs[5]{Content} = $app_req_tmp ;
		
		# push data out of the thread to the while loop
		$DataQueue->enqueue($svr);
		
	} else {
		# we will dry run - no actual response is set

		# fake wait for response
		sleep rand(3);

		# push fake data out of the thread to the while loop
		$DataQueue->enqueue(int(rand($maximum)));
		
	}
}

sub my_alarm {
	$timeout *= -1;
	my_exit();
}

sub my_exit {

	# Loop through all the threads and join them for cleaning up
	foreach my $thread (threads->list) { 
		# Don't join the main thread or ourselves 
		if ($thread->tid && !threads::equal($thread, threads->self)) { 
			#$thread->join; 
			$thread->detach; 
			##$thread->exit();
		} 
	}

	my $status ; 
	$count = scalar keys %app_loc_servers ;

	if ($count > $warning) {
		$status = "OK";
	} elsif ($count > $critical) { 
		$status = "WARNING";
	} else {
		$status = "CRITICAL";
	}

	if (@_) { print "Citrix XML service $_[0]\n" }
	print "Citrix-XML-service ";
	print "$status. ";
	if ($timeout < 0) { print "timeout after ". $timeout * -1 . " seconds. "; }
	print "located \"$pub_app\" $count times with $requests requests.";
 	if ($verbose >= 3) {
		print STDERR "the following servers answered (x times):" ;
		foreach my $key (sort keys %app_loc_servers) {
			print STDERR "\n$key ($app_loc_servers{$key})" ;
		}
		print STDERR "\n" ;
	}
	exit $ERRORS{$status} ;
}

sub valid_xml {
	my ($p, $input) = @_ ;

	%xml_tag   = () ;
	@tag_stack = () ;

	eval {
	$p->parse($input)
	} ;

	return (0, qq(XML::Parser->parse failed: Bad XML in "$input".!))
		if $@ ;

	if ( $xml_debug ) {
	print STDERR pack('A4 A30 A40', ' ', $_, qq(-> "$xml_tag{$_}")), "\n"
		foreach (keys %xml_tag)
	}

	return (1, 'valid xml')

}


sub handle_start {
	push @tag_stack, $_[1] ;

	$xml_debug		&& print STDERR pack('A8 A30 A40', ' ', 'handle_start - tag', " -> '$_[1]'"), "\n" ;
	$xml_debug 		&& print STDERR pack('A8 A30 A60', ' ', 'handle_start - @tag_stack', " -> (@tag_stack)"), "\n" ;
}

sub handle_char {
	my $text = $_[1] ;

	!($text =~ /\S/  || $text =~ /^[ \t]$/)       && return ;

	$text =~ s/\n//g ;

	my $tag = $tag_stack[-1] ;

	$xml_debug 		&& print STDERR pack('A8 A30 A30', ' ', 'handle_char - tag', " -> '$tag'"), "\n" ;
	$xml_debug 		&& print STDERR pack('A8 A30 A40', ' ', 'handle_char - text', " -> '$text'"), "\n" ;

	$xml_tag{$tag} .= $text ;

}


sub print_help() {

#          1        2         3         4         5         6         7         8
#12345678901234567890123456789012345678901234567890123456789012345678901234567890

	print_revision($PROGNAME,'0.2');

my $help = <<EOHELP ;
Copyright (c) 2004 Karl DeBisschop/S Hopcroft
Copyright (c) 2008 Birger Schmidt (Netways GmbH)

$PROGNAME -P <pn_server> -A app -F <Farm> --maximum <expected servers>
      -w <warning threshold> -c <critical threshold> -M <max_requests>
      -t <timeout> [-v -x -h -V]

Check the Citrix Metaframe XP service by completing an HTTP dialogue with a Program
Neigbourhood server (pn_server) that returns an ICA server in the named Server farm
hosting the specified applications (an ICA server in a farm which runs some MS app).
Ask as many times as necessary to find out how many different ICA servers offer the
application.
EOHELP

	print $help ;
	print "\n";
	print "\n";
	print_usage();
	print "\n";
	support();
}

sub print_usage () {

#          1        2         3         4         5         6         7         8
#12345678901234567890123456789012345678901234567890123456789012345678901234567890

my $usage = <<EOUSAGE ;
$PROGNAME
[-P | --pn_server]    The name or address of the Citrix Metaframe XP
                      Program Neigbourhood server (required).
[-A | --pub_app]      The name of an application published by the server farm 
                      (default 'Word 2003').
[-F | --server_farm]  The name of a Citrix Metaframe XP server farm. (required)
[-m | --maximum]      The maximum number of ICA servers that could offer the
                      service in total (required).
[-w | --warning]      If less or equal servers offered the result will be warning.
[-c | --critical]     If less or equal servers offered the result will be critical.
[-M | --max_requests] Don't send more requests than specified.
[-t | --timeout]      Timeout as usual in seconds.
[-v | --verbose]      Level of verbosity
[-h | --help]         The help text an usage.
[-x | --xml_debug]    Print XML requests and answers.
[-V | --version]      Print version of the plugin.

example:
./$PROGNAME -P pnserver -A windows -F farm -w 20 -c 25 -m 28 -M 200 -t 5 

EOUSAGE

	print $usage ;

}

sub usage {
	&print_usage ;
	exit $ERRORS{'OK'} ;
}

sub version () {
	#print_revision($PROGNAME,'$Revision: 1097 $ ');
	print_revision($PROGNAME,'0.2');
	exit $ERRORS{'OK'};
}

sub help () {
	print_help();
	exit $ERRORS{'OK'};
}


=begin comment

This is the set of requests and responses transmitted between a Citrix Metaframe XP Program Neigbourhood (PN) client and a PN server.

This dialogue was captured by and reconstructed from tcpdump.

Citrix are not well known for documenting their protocols although the DTD may be informative. Note that the pair(s) 0 and 1, 4 and 5, ...
do not appear to do anything.

req 0
POST /scripts/WPnBr.dll HTTP/1.1
Content-type: text/xml
Host: 10.1.2.2:80
Content-Length: 220
Connection: Keep-Alive


<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1"><RequestProtocolInfo><ServerAddress addresstype="dns-port" /></RequestProtocolInfo></NFuseProtocol>

HTTP/1.1 100 Continue
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:12:40 GMT


resp 1
HTTP/1.1 200 OK
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:12:40 GMT
Content-type: text/xml
Content-length: 253


<?xml version="1.0" encoding="ISO-8859-1" ?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
    <ResponseProtocolInfo>
      <ServerAddress addresstype="no-change"></ServerAddress>
    </ResponseProtocolInfo>
</NFuseProtocol>

req 2
POST /scripts/WPnBr.dll HTTP/1.1
Content-type: text/xml
Host: 10.1.2.2:80
Content-Length: 191
Connection: Keep-Alive


<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1"><RequestServerFarmData><Nil /></RequestServerFarmData></NFuseProtocol>

HTTP/1.1 100 Continue
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:12:40 GMT


resp 3
HTTP/1.1 200 OK
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:12:40 GMT
Content-type: text/xml
Content-length: 293


<?xml version="1.0" encoding="ISO-8859-1" ?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
    <ResponseServerFarmData>
      <ServerFarmData>
        <ServerFarmName>FOOFARM01</ServerFarmName>
      </ServerFarmData>
    </ResponseServerFarmData>
</NFuseProtocol>

req 4
POST /scripts/WPnBr.dll HTTP/1.1
Content-type: text/xml
Host: 10.1.2.2:80
Content-Length: 220
Connection: Keep-Alive


<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1"><RequestProtocolInfo><ServerAddress addresstype="dns-port" /></RequestProtocolInfo></NFuseProtocol>

HTTP/1.1 100 Continue
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:12:55 GMT


resp 5
HTTP/1.1 200 OK
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:12:55 GMT
Content-type: text/xml
Content-length: 253


<?xml version="1.0" encoding="ISO-8859-1" ?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
    <ResponseProtocolInfo>
      <ServerAddress addresstype="no-change"></ServerAddress>
    </ResponseProtocolInfo>
</NFuseProtocol>

req 6
POST /scripts/WPnBr.dll HTTP/1.1
Content-type: text/xml
Host: 10.1.2.2:80
Content-Length: 442
Connection: Keep-Alive


<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
<RequestAddress><Name>
  <UnspecifiedName>FOOFARM01*</UnspecifiedName>
  </Name><ClientName>WS09535</ClientName>
  <ClientAddress addresstype="dns-port" />
  <ServerAddress addresstype="dns-port" />
  <Flags />
  <Credentials>
    <UserName>foo-user</UserName>
    <Domain>some-domain</Domain>
  </Credentials>
</RequestAddress></NFuseProtocol>

HTTP/1.1 100 Continue
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:12:56 GMT


resp 7
HTTP/1.1 200 OK
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:12:56 GMT
Content-type: text/xml
Content-length: 507


<?xml version="1.0" encoding="ISO-8859-1" ?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
    <ResponseAddress>
      <ServerAddress addresstype="dot-port">10.1.2.2:1494</ServerAddress>
      <ServerType>win32</ServerType>
      <ConnectionType>tcp</ConnectionType>
      <ClientType>ica30</ClientType>
      <TicketTag>10.1.2.2</TicketTag>
      <SSLRelayAddress addresstype="dns-port">ica_svr01.some.domain:443</SSLRelayAddress>
    </ResponseAddress>
</NFuseProtocol>

req 8
POST /scripts/WPnBr.dll HTTP/1.1
Content-type: text/xml
Host: 10.1.2.2:80
Content-Length: 220
Connection: Keep-Alive


<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1"><RequestProtocolInfo><ServerAddress addresstype="dns-port" /></RequestProtocolInfo></NFuseProtocol>

HTTP/1.1 100 Continue
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:13:29 GMT


resp 9
HTTP/1.1 200 OK
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:13:29 GMT
Content-type: text/xml
Content-length: 253


<?xml version="1.0" encoding="ISO-8859-1" ?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
    <ResponseProtocolInfo>
      <ServerAddress addresstype="no-change"></ServerAddress>
    </ResponseProtocolInfo>
</NFuseProtocol>

req 10
POST /scripts/WPnBr.dll HTTP/1.1
Content-type: text/xml
Host: 10.1.2.2:80
Content-Length: 446
Connection: Keep-Alive


<?xml version="1.0" encoding="ISO-8859-1"?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
<RequestAddress>
  <Name>
    <UnspecifiedName>EXCEL#32;2003</UnspecifiedName>
  </Name>
  <ClientName>WS09535</ClientName>
  <ClientAddress addresstype="dns-port" />
  <ServerAddress addresstype="dns-port" />
  <Flags />
    <Credentials><UserName>foo-user</UserName>
      <Domain>some-domain</Domain>
    </Credentials>
</RequestAddress>
</NFuseProtocol>

HTTP/1.1 100 Continue
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:13:29 GMT


resp 11
HTTP/1.1 200 OK
Server: Citrix Web PN Server
Date: Thu, 30 Sep 2004 00:13:29 GMT
Content-type: text/xml
Content-length: 509


<?xml version="1.0" encoding="ISO-8859-1" ?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
    <ResponseAddress>
      <ServerAddress addresstype="dot-port">10.1.2.14:1494</ServerAddress>
      <ServerType>win32</ServerType>
      <ConnectionType>tcp</ConnectionType>
      <ClientType>ica30</ClientType>
      <TicketTag>10.1.2.14</TicketTag>
      <SSLRelayAddress addresstype="dns-port">ica_svr02.some.domain:443</SSLRelayAddress>
    </ResponseAddress>
</NFuseProtocol>

** One sees this XML on an error (there may well be other error XML also, but I haven't seen it) **

<?xml version="1.0" encoding="ISO-8859-1" ?>
<!DOCTYPE NFuseProtocol SYSTEM "NFuse.dtd">
<NFuseProtocol version="1.1">
    <ResponseAddress>
      <ErrorId>unspecified</ErrorId>
      <BrowserError>0x0000000E</BrowserError>
    </ResponseAddress>
</NFuseProtocol>


=end comment

=cut


# You never know when you may be embedded ...


# vim: set ai,ts=8
