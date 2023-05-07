#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use CGI qw(escapeHTML);
use IPC::Open2;

use lib "${Bin}/..";

sub ui_zenity_sub(&) {
    my ($routine) = @_;

    eval { &$routine(); };

    system 'zenity', '--error', '--text', escapeHTML($@) if ($@);
}

sub ui_zenity_run(@) {
    my ($zinput, @zargs) = @_;

    my $ret;
    my ($zenity_out, $zenity_in);
    my $pid = open2($zenity_out, $zenity_in, 'zenity', @zargs);
    binmode $zenity_out, ':utf8';
    binmode $zenity_in, ':utf8';
    print $zenity_in $zinput if defined $zinput;
    {
        local $/;undef $/;
        $ret = <$zenity_out>;
    }
    waitpid $pid, 0;
    my $status = $?;
    close $zenity_out;
    close $zenity_in;

    return undef if $status;
    return $ret;
}

1;
