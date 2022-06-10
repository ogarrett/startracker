#!/usr/bin/perl -w

use strict;
use warnings;

use LWP::UserAgent;
use JSON;
use POSIX qw(strftime);
use Time::Local;


my $json_text = do {
	open( my $fh, "<", ".gh_creds" ) or die( "Can't open .gh_creds: $!");
	local $/;
	<$fh>
};

my $p = decode_json( $json_text );
my( $gh_user, $apitoken ) = ( $p->{"user"}, $p->{"pass"} );

=pod
On each run:

Find the most recent .tsv in ./cache/cache*.tsv
Read it into two datastructures:

First line == 'Date' and list of repositories
Subsequent lines:
Array of dates
	If no timestamp, assume 23:50 UTC
Hash of arrays of data, one per repository
	If no data, record '-1'

Prepend current star count onto each array (and current date onto array of dates)

For each repo:
	Scan array and look for oldest date with count == -1
	Update repo array:
		Grab data up to that date
		For each date, count stars /after/ that date, then subtract from current stars

Output data as cache/cache-TIME.tsv

Generate data for normalized timestamps:
	Yesterday, 23:59:59 UTC
	previous days.... as available
... interprolating the star data

Output normalized data as stars.tsv

=cut



# Find newest data file cache/cache-*.tsv

my $dir = "cache";
opendir my $dh, $dir or die "Could not open $dir: $!";

my( $newest_name, $newest_time ) = ( undef, 2**31 -1 );
while( defined( my $file = readdir( $dh ) ) ) {
	next if $file !~ /cache-.*\.tsv/;
	( $newest_name, $newest_time ) = ( $file, -M _ ) if( -M "$dir/$file" < $newest_time );
}
print STDERR "Reading raw samples in: $dir/$newest_name\n";

# Read raw data
open IN, "< $dir/$newest_name" or die "Could not read $dir/$newest_name: $!";

my $header = <IN>;
chomp $header;
my @repos = split /\t/, $header;

my $t = shift @repos; die "$t -ne 'Date'" if $t ne "Date";


# Read and process input
my @date = ();
my %stars = ();
$stars{$_} = [] foreach @repos;

while(<IN>) {
	chomp;
	my @line = split /\t/, $_;
	my $date = shift @line;
	$date .= "T23:59:59" if $date =~ /^20\d\d-\d\d-\d\d$/;

	push @date, $date;
	foreach( @repos ) {
		my $c = shift @line; $c = -1 if !defined $c;
		push @{$stars{$_}}, $c;
	}
}


# Get new stars

my %stargazers_url;
my %stargazers_count;

print STDERR "  Getting GitHub stars ";
foreach my $repo ( @repos ) {
	print STDERR ".";
 	# Get metadata for repository or die()

	# curl -ni "https://api.github.com/repos/deepfence/ThreatMapper" -H 'Accept: application/vnd.github.preview'
	# curl -u ogarrett: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 for higher rate limit!

	my $uri = "https://api.github.com/repos/$repo";
	my $ua = LWP::UserAgent->new( ssl_opts => { verify_hostname => 0 } );
	my $req = HTTP::Request->new( "GET", $uri, [ "Accept", "application/vnd.github.preview" ] );
	$req->authorization_basic($gh_user, $apitoken);

	my $resp = $ua->request($req);

	die( sprintf "GET $uri failed: %s %s", $resp->code, $resp->message ) if( ! $resp->is_success );

	my $r = decode_json( $resp->decoded_content );
	
	$stargazers_count{$repo}  = $r->{"stargazers_count"};
	$stargazers_url{$repo}    = $r->{"stargazers_url"};
	
	unshift @{$stars{$repo}}, $stargazers_count{$repo};

	
}

# now in UTC
my $nowt = time();
my $now = strftime( "%FT%X", gmtime( $nowt ) );
unshift @date, $now;
print STDERR " done\n";


# Get any missing data
# This code is only triggered if we add a new column to the input data
# Note, we handle all dates as strings because this works for comparisons

print STDERR "  Getting missing data ";
foreach my $repo ( @repos ) {
	print STDERR ".";

	# find the oldest missing datapoint
	my $i = $#date;
	while( $i > 0 ) {
		last if $stars{$repo}[$i] < 0;
		$i--;
	}
	next if( $i == 0 );

	print STDERR "\n    - $repo from $date[$i] ";

	my @stardates;

	my $uri = sprintf "$stargazers_url{$repo}?per_page=%d&page=%d", 100, int( $stargazers_count{$repo}/100 )+1;
	while( $uri ) {
		print STDERR '.';
		my $ua = LWP::UserAgent->new( ssl_opts => { verify_hostname => 0 } );
		my $req = HTTP::Request->new( "GET", $uri, [ "Accept", "application/vnd.github.v3.star+json" ] );
		$req->authorization_basic($gh_user, $apitoken);
		my $resp = $ua->request($req);

		# Pagination failed for large resources e.g. kubernetes/kubernetes
		if( $resp->code == "422" ) {
			print STDERR " Pagination failed "; last;
		}

		die( sprintf "GET $uri failed: %s %s", $resp->code, $resp->message ) if( ! $resp->is_success );

		my $r = decode_json( $resp->decoded_content );

		# most recent (largest) first
		push @stardates, sort { $b cmp $a } map { $_->{starred_at} } @$r;

		if( @stardates && $stardates[-1] lt $date[$i] ) {
			print STDERR " stopping at $stardates[-1] "; last;
		}

		my $next_uri;
		if( defined $resp->header( "Link" ) ) { 
			my $link;
			map { /<(.*?)>; rel="(.*?)"/; $link->{$2} = $1 } split /, /, $resp->header( "Link" );
			$next_uri = $link->{prev};
		}
		if( ! $next_uri ) {
			print STDERR " EOF "; last;
		}
		$uri = $next_uri;
	}

	# now, @stardates contains all of the star dates later than $date[$i] (and some earlier than too)
	# count the number of dates that are more recent than the desired date, and subtract from
	# the current number of stars

	while( $i > 0 ) {
		my $k = grep { $_ gt "$date[$i]" } @stardates;


if( $k > $stargazers_count{$repo} ) {
	print STDERR "Too many stargazers: $k > $stargazers_count{$repo}!\n";
	print STDERR join "\t", @stardates;
	print STDERR "\n";
}


		$stars{$repo}[$i] = $stargazers_count{$repo} - $k;
		$i--;
	}
}

print STDERR " done\n";



# write raw data
my $output = "cache/cache-$now.tsv";
print STDERR "Writing raw samples to: $output ..";

open OUT, ">$output" or die ("Can't open $output for writing: $!");
print OUT "Date\t", join "\t", @repos; print OUT "\n";
for( my $i = 0; $i <= $#date; $i++ ) {
	my @line = ( $date[$i] );
	push @line, $stars{$_}->[$i] foreach @repos;
	print OUT join "\t", @line; print OUT "\n";
}
close OUT;
print STDERR " done\n";


print STDERR "Linking raw samples to: cache.tsv ..";
unlink( "cache.tsv" ) or print STDERR "Could not remove cache.tsv: $!";
symlink( $output, "cache.tsv") or print STDERR "Could not symlink $output to cache.tsv: $!";
print STDERR " done\n";


# write interpolated data
$output = "stars.tsv";
print STDERR "Writing star counts to: $output ..";

open OUT, ">$output" or die ("Can't open $output for writing: $!");
print OUT "Date\t", join "\t", @repos; print OUT "\n";

# To interpolate, we're going to need to convert dates to timestamps
# 2022-04-26T09:35:22 -> unixtime
my @datet = map { 
	my( $Y, $M, $D, $h, $m, $s ) = ( $_ =~ /(\d\d\d\d)\-(\d\d)\-(\d\d)T(\d\d)\:(\d\d)\:(\d\d)/ ); timegm( $s, $m, $h, $D, $M-1, $Y); 
} @date;

# debug - did we correctly convert times?
#for( my $i = 0; $i <= $#date; $i++ ) {
#	print STDERR "$date[$i] => " . strftime( "%FT%X", gmtime( $datet[$i] ) ) . "\n";
#}


# $stampt = yesterdayT23:59:59
my $stampt = $nowt - ( $nowt % (24*3600) ) - 1;
while( $stampt > $datet[$#datet] ) {

	# datet is in descending order
	my $i = 0;
	$i++ while( ! ($datet[$i+1] < $stampt ) );

	# datet[$i] >= $stampt && datet[$i+1] < $stampt
	#print STDERR "  $date[$i] >= ".strftime( "%FT%X", gmtime( $stampt ) )." > $date[$i+1] $datet[$i] >= $stampt > $datet[$i+1] ($i)\n";
	

	my @line = ( strftime( "%F", gmtime( $stampt ) ) );
	foreach ( @repos ) {
		push @line, int( $stars{$_}->[$i] * (1-($datet[$i]-$stampt)/($datet[$i]-$datet[$i+1])) + $stars{$_}->[$i+1] * (1-($stampt-$datet[$i+1])/($datet[$i]-$datet[$i+1])) + 0.5 );
	}
	print OUT join "\t", @line; print OUT "\n";

	$stampt -= 24*3600;
}

close OUT;
print STDERR " done\n";

