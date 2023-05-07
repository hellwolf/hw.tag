## Internal Files
#    data directory: data/
#    $entry: hwtagE[title] -> data/$entrydst
#    $tagdesc: hwtagT[tagnode]([!tagnode])*(!![title])? -> hwtagE
#
## Naming Conventions
#    $category: Name of the category.
#    $category_config: Configuration of certain category.
#        {
#            lib => $dir_name,
#            export => $dir_name,
#            post_import_sub => sub (optional)
#        }
#    $taglink: Link list of tagnodes
#        [$tagnode, ...]
#    $tag: Tag description
#        [$title, $taglink]
#    $edir: Entity directory name located in $category_config->{lib}.
#        The format is: $category_config->{lib}/num1/num2/num3
#        The range of num is from 00 to 99, two digits.
#    $entity_number : Category-wide unique number of entity.
#        It's simply the combination of ${num1}${num2}${num3}
#    $etag: Exported tag file name located in $category_config->{export}.
#    $basemeta: Entity description, handler for operations
#        {
#            category => $category_name,
#            edir => $edir
#        }
#
## Error Handling Policy
#    Die if anything wrong happens.

use strict;
use warnings;
use utf8;

package HWTAG::Config;
# default configurations
my %config_default = (
    category => {},
);

# config file should operate on this variable
our %config;

sub load($$) {
    my ($config_file, $config) = @_;
    %config = %config_default;
    unless (my $return = do $config_file) {
        die "couldn't parse config file: $@" if $@;
        die "couldn't do config file: $!"    unless defined $return;
        die "couldn't run config file"       unless $return;
    }

    # copy instead of reference for multiple instances of objects having
    # different configurations.
    %$config = %config;
}


package HWTAG;

use Cwd qw();
use File::Spec::Functions qw(catfile catdir abs2rel);
use File::Glob qw();
use File::Copy qw(mv copy);
use File::Basename qw(basename dirname);

############################################################
# Internal functions
############################################################
# workaround for functions that don't cope with utf8 well
sub to_utf8($) {
    my ($str) = @_;
    utf8::decode($str) unless utf8::is_utf8($str);
    return $str;
}
sub all_to_utf8(@) {
    utf8::is_utf8($_) || utf8::decode($_) for @_;
}
sub readlink_utf8($) {
    my ($filename) = @_;
    return to_utf8(readlink($filename));
}
sub realpath($) { return to_utf8(Cwd::realpath(@_)); }
sub bsd_glob($) { return map {to_utf8($_)} File::Glob::bsd_glob(@_); }

# find the next availabe number in directory
sub dir_find_next_number($$) {
    my ($dir, $len) = @_;

    my $rt;
    opendir DIR, $dir or die "Can not open directory: $dir\n";
    my @ndirs = sort { $b <=> $a } grep /^\d{$len}$/, readdir(DIR);
    if (@ndirs) {
        $rt = $ndirs[0];
    } else {
        $rt = -1;
    }
    close DIR;
    return $rt;
}

############################################################
# Object methods
############################################################
# name: new
# summary: construction function
# arguments:
#     $config_file: alternative configuration file(optional)
# return: $self(object reference)
sub new {
    my ($CLASS, $config_file, $option) = @_;
    my $self = {
        config => {},
        option => $option || {}
    };

    $config_file ||= $ENV{HWTAG_CONFIG};
    $config_file ||= catfile($ENV{HOME}, '.hwtag.pl');

    HWTAG::Config::load($config_file, $self->{config});

    #config check and canonicalize
    for my $category_config (values %{$self->{config}{category}}){
        $category_config->{lib} = realpath($category_config->{lib});
        $category_config->{export} = realpath($category_config->{export});
        $category_config->{export_title} = catdir($category_config->{export}, '#title')
            unless exists $category_config->{export_title};
        $category_config->{export_untagged} = catdir($category_config->{export}, '#untagged')
            unless exists $category_config->{export_untagged};
        unless ($category_config->{no_titletag}) {
            mkdir $category_config->{export_title}
                unless -d $category_config->{export_title};
        }
        $category_config->{trash} ||= catdir($category_config->{lib}, 'trash');
        mkdir $category_config->{trash}
            unless -d $category_config->{trash};
    }

    return bless $self, $CLASS;
}

# name: category_list
# summary: list available categories
# arguments: none
# return: ($category, ...)
sub category_list {
    my ($self) = @_;

    return keys %{$self->{config}{category}};
}

# name: category_get_config
# summary: get configurations for certain category
# arguments:
#     $category
# return: $category_config
sub category_get_config {
    my ($self, $category) = @_;
    all_to_utf8($category);

    die "No such category: $category"
        unless exists $self->{config}{category}{$category};
    return $self->{config}{category}{$category};
}

# name: get_basemeta_from_edir
# summary: get basemeta from edir
# arguments:
#     $edir
# return: $basemeta
sub get_basemeta_from_edir {
    my ($self, $edir) = @_;

    die "Not a valid directory: $edir" unless -d $edir;
    $edir = realpath($edir);

    # find corresponding category
    my $category;
    for my $c (keys %{$self->{config}{category}}) {
        if ($edir =~ m:^\Q$self->{config}{category}{$c}{lib}\E/:) {
            $category = $c;
            last;
        }
    }
    die "Cannot find category for edir: $edir" unless defined $category;

    return {category => $category, edir => $edir};
}

# name: get_basemeta_from_etag
# summary: get basemeta from etag
# arguments:
#     $etag
# return : $basemeta
sub get_basemeta_from_etag {
    my ($self, $etag) = @_;

    my $edir;

    # check if it's auto tags
    my $etag_dirname = realpath(dirname($etag));
    for my $c (keys %{$self->{config}{category}}) {
        if (($etag_dirname eq $self->{config}{category}{$c}{export_title}) ||
            ($etag_dirname eq $self->{config}{category}{$c}{export_untagged})) {
            my $entrylink = readlink_utf8($etag);
            die "Not a valid auto etag: $etag"
                unless $entrylink && $entrylink =~ m:/hwtagE[^/]+$:;
            $edir = dirname($entrylink);
        }
    }

    # check if it's normal tag
    unless ($edir) {
        my $tagdesc_file = readlink_utf8($etag);
        die "Not an etag: $etag" unless $tagdesc_file;
        my $entrylink = readlink_utf8($tagdesc_file);
        die "Not a valid etag: $etag"
            unless defined $entrylink && $entrylink =~ m:^hwtagE[^/]+$:;
        $edir = dirname($tagdesc_file);
    }

    return $self->get_basemeta_from_edir($edir);
}

# name: entity_import
# summary: import files to library
# arguments:
#     $category
#     $title
#     @files: absolute names of files to import
#             the first file is the entry destination
# return: $basemeta
sub entity_import {
    my ($self, $category, $title, @files) = @_;
    all_to_utf8($category, $title);

    my $category_config = $self->category_get_config($category);

    # arguments checking
    die "Title not defined" unless $title;
    $self->check_title($title) if $title;
    die "There should be at list one file to import" unless @files;
    die "Files in files list are not all exist"
        unless grep { -e $_ } @files;
    for my $file (@files) {
        $file = realpath($file);
        for my $c (keys %{$self->{config}{category}}) {
            die "$file is in ${c}'s lib directory"
                if $file =~ m:^\Q$self->{config}{category}{$c}{lib}/\E:;
            die "$file is in ${c}'s export directory"
                if $file =~ m:^\Q$self->{config}{category}{$c}{export}/\E:;
        }
    }

    # create edir in lib
    my ($n1, $n2, $n3);
    $n1 = dir_find_next_number($category_config->{lib}, 2);
    $n1 = '00' if $n1 == -1;
    mkdir $category_config->{lib}.'/00' if $n1 eq '00';
    $n2 = dir_find_next_number(catdir($category_config->{lib}, $n1), 2);
    $n2 = '00' if $n2 == -1;
    mkdir $category_config->{lib}.'/00/00' if $n2 eq '00';
    $n3 = dir_find_next_number(catdir($category_config->{lib}, $n1, $n2), 2);
    if ($n3 == 99) {
        if ($n2 == 99) {
            ++$n1;$n1 = sprintf '%02d', $n1;
            mkdir catdir($category_config->{lib}, $n1);
            $n2 = '00';
            mkdir catdir($category_config->{lib}, $n1, $n2);
            $n3 = '00';
        } else {
            ++$n2;$n2 = sprintf '%02d', $n2;
            mkdir catdir($category_config->{lib}, $n1, $n2);
            $n3 = '00';
        }
    } else {
        ++$n3;$n3 = sprintf '%02d', $n3;
    }
    my $edir = catdir($category_config->{lib}, $n1, $n2, $n3);
    mkdir $edir;
    my $edir_data = catdir($edir, 'data');
    mkdir $edir_data;

    # move files into destination directory, make entry link
    my $entrydst = basename($files[0]);
    my $entry = 'hwtagE'.$title;
    eval {
        for (@files) {
            if ($self->{option}{no_delete}) {
                copy $_, catfile($edir_data, basename($_))
                    or die "mv $_ -> $edir_data: $!";
            } else {
                mv $_, catfile($edir_data, basename($_))
                    or die "mv $_ -> $edir_data: $!";
            }
        }
        symlink catfile('data', $entrydst), catfile($edir, $entry)
            or die "symlink $entry -> $entrydst failed: $!";
    };
    if ($@) {
        # reverse operations
        for (@files) {
            if ($self->{option}{no_delete}) {
            } else {
                mv catfile($edir_data, basename($_)), $_
                    if -e catfile($edir_data, basename($_));
            }
        }
        unlink catfile($edir, $entrydst);
        rmdir $edir_data;
        rmdir $edir;
        die $@;
    }

    my $basemeta = {category => $category, edir => $edir};

    $self->entity_sync_autotags($basemeta);

    # post import function
    if (exists $category_config->{post_import_sub}) {
        $category_config->{post_import_sub}($self,
                                            $basemeta,
                                            $title,
                                            @files);
    }

    return $basemeta;
}

# name: entity_delete
# summary: remove entity from library
# arguments:
#     $basemeta
# return: none
sub entity_delete {
    my ($self, $basemeta) = @_;

    my $category_config = $self->category_get_config($basemeta->{category});
    my $entity_number = $self->get_entity_number($basemeta);
    my $title = $self->entity_get_title($basemeta);

    # remove each tag
    for my $tag ($self->tag_list($basemeta)){
        $self->tag_remove_by_tag($basemeta, $tag);
    }

    # remove autotags
    my @tags_title_old = bsd_glob($category_config->{export_title}."/$entity_number - *");
    my @tags_untagged_old = bsd_glob($category_config->{export_untagged}."/$entity_number - *");
    unlink @tags_title_old, @tags_untagged_old;
    # remove if it's empty
    rmdir $category_config->{export_untagged};

    # remove entity
    mv $basemeta->{edir}, catdir($category_config->{trash}, $title);
}

# name: entity_get_title
# summary: get title of the entity
# arguments:
#     $basemeta
# return: $title
sub entity_get_title {
    my ($self, $basemeta) = @_;

    my ($entry_file) = bsd_glob($basemeta->{edir}.'/hwtagE*');
    my ($title) = ($entry_file =~ m:^\Q$basemeta->{edir}\E/hwtagE(.*)$:);
    die "Cannot get title" unless $title;

    return $title;
}

# name: entity_set_title
# summary: set title of the entity
# arguments:
#     $basemeta
#     $new_title: new title
# return: none
sub entity_set_title {
    my ($self, $basemeta, $new_title) = @_;
    all_to_utf8($new_title);

    die "unimplemented entity_set_title";
}

# name: entity_get_entry
# summary: get entry of the entity
# arguments:
#     $basemeta
# return: $entry
sub entity_get_entry {
    my ($self, $basemeta) = @_;

    my ($entry_file) = bsd_glob($basemeta->{edir}.'/hwtagE*');
    die "Get entry file failed" unless $entry_file;
    my ($entry) = ($entry_file =~ m:^\Q$basemeta->{edir}\E/(.*):);

    return $entry;
}

# name: entity_get_entrydst
# summary: get entrydst of the entity
# arguments:
#     $basemeta
# return: $entrydst
sub entity_get_entrydst {
    my ($self, $basemeta) = @_;

    my $entrydst;
    die "unimplemented entity_get_entrydst";

    return $entrydst;
}

# name: entity_set_entrydst
# summary: set entrydst of the entity
# arguments:
#     $basemeta
#     $new_entrydst: new entrydst
# return: none
sub entity_set_entrydst {
    my ($self, $basemeta, $new_entrydst) = @_;
    all_to_utf8($new_entrydst);

    die "unimplemented entity_set_entrydst";
}

# name: entity_sync_autotags
# summary: update autotags for entity
# arguments:
#     $basemeta
# return: none
sub entity_sync_autotags {
    my ($self, $basemeta) = @_;

    my $category_config = $self->category_get_config($basemeta->{category});

    # autotag file name
    my $entity_number = $self->get_entity_number($basemeta);
    my $title = $self->entity_get_title($basemeta);
    my $entry = 'hwtagE'.$title;
    my $num_entry = $entity_number.' - '.$title;

    # sync title autotag
    unless ($category_config->{no_titletag}) {
        my $tag_title = catfile($category_config->{export_title}, $num_entry);
        my @tags_title_old = bsd_glob($category_config->{export_title}."/$entity_number - *");
        unless ((@tags_title_old == 1) &&
                    ($tags_title_old[0] =~ m:/\Q$num_entry\E$:)) {
            unlink @tags_title_old;
            symlink catfile($basemeta->{edir}, $entry), $tag_title;
        }
    }

    # sync untagged autotag
    my $tag_untagged = catfile($category_config->{export_untagged}, $num_entry);
    my @tags_untagged_old = bsd_glob($category_config->{export_untagged}."/$entity_number - *");
    if ($self->tag_list($basemeta)) {
        unlink @tags_untagged_old;
    }else{
        unless ((@tags_untagged_old == 1) &&
                    ($tags_untagged_old[0] =~ m:/\Q$num_entry\E$:)) {
            unlink @tags_untagged_old;
            mkdir $category_config->{export_untagged}
                unless -d $category_config->{export_untagged};
            symlink catfile($basemeta->{edir}, $entry), $tag_untagged;
        }
    }

    # remove empty untagged autotag dir
    rmdir $category_config->{export_untagged};
}

# name: tag_add
# summary: add tag for entity
# arguments:
#    $basemeta
#    $tag
# return :  $etag
sub tag_add {
    my ($self, $basemeta, $tag) = @_;
    my ($title, $taglink) = $self->check_tag($tag);

    my $category_config = $self->category_get_config($basemeta->{category});

    # arguments checking
    for (@$taglink) {
        die "Tag cannot contain '!' character" if $_ =~ m:!:;
        die "Tag cannot contain '/' character" if $_ =~ m:/:;
        die "Tag cannot start with '#' character" if $_ =~ m:^#:;
    }

    # tag directory
    my $tdir = catdir($category_config->{export}, @$taglink);

    # build tag description file name
    my $dest_name = $tag->[0] || $self->entity_get_title($basemeta);
    my $tagdesc = $self->calc_tagdesc_from_tag($basemeta, $tag);

    # create tag description file
    my $entry = $self->entity_get_entry($basemeta);
    die "Tag description file already exists"
        if -f catfile($basemeta->{edir}, $tagdesc);
    symlink $entry, catfile($basemeta->{edir}, $tagdesc) or
        die "Create symlink $basemeta->{edir}/$tagdesc failed: $!";
    die "Tag exported" if -f catfile($tdir, $dest_name);
    symlink catfile($basemeta->{edir}, $tagdesc), catfile($tdir, $dest_name) or
        die "Create symlink $tdir/$dest_name failed: $!";

    $self->entity_sync_autotags($basemeta);
}

# name _tag_remove_by_tag
# summary: internal function to remove tag
sub _tag_remove {
    my ($self, $basemeta, $tag, $etag) = @_;

    die "Can not delete autotag" if $self->is_autotag($tag);

    my $tagdesc = $self->calc_tagdesc_from_tag($basemeta, $tag);
    unlink $etag, catfile($basemeta->{edir}, $tagdesc);
    $self->entity_sync_autotags($basemeta);
}

# name: tag_remove_by_tag
# summary: remove tag of entity by specify $tag
# arguments:
#     $basemeta
#     $tag
# return: none
sub tag_remove_by_tag {
    my ($self, $basemeta, $tag) = @_;
    my ($title, $taglink) = $self->check_tag($tag);

    my $etag = $self->get_etag_from_tag($basemeta, $tag);

    $self->_tag_remove($basemeta, $tag, $etag);
}

# name: tag_remove_by_etag
# summary: remove tag of entity by specify $etag
# arguments:
#     $basemeta
#     $etag
# return: none
sub tag_remove_by_etag {
    my ($self, $basemeta, $etag) = @_;

    my $tag = $self->get_tag_from_etag($basemeta, $etag);

    $self->_tag_remove($basemeta, $tag, $etag);
}

# name: tag_set_tagtitle_by_tag
# summary: set title for certain tag
# arguments:
#     $basemeta
#     $tag
#     $new_title: new title
# return: $etag
sub tag_set_tagtitle_by_tag {
    my ($self, $basemeta, $tag, $new_title) = @_;
    my ($title, $taglink) = $self->check_tag($tag);
    all_to_utf8($new_title);

    # create new tag
    my $newtag = [$new_title, $taglink];
    my $oldtag_desc = $self->calc_tagdesc_from_tag($basemeta, $tag);
    my $newtag_desc = $self->calc_tagdesc_from_tag($basemeta, $newtag);
    return if $oldtag_desc eq $newtag_desc;
    # move tagdesc
    mv catfile($basemeta->{edir}, $oldtag_desc),
        catfile($basemeta->{edir}, $newtag_desc)
            or die "mv $oldtag_desc -> $newtag_desc: $!";
    # move etag
    my $etag = $self->get_etag_from_tag($basemeta, $tag);
    my $etagdir = realpath(dirname($etag));
    unlink $etag;
    symlink catfile($basemeta->{edir}, $newtag_desc),
        catfile($etagdir, $new_title)
            or die "symlink $etagdir/$new_title -> $newtag_desc failed: $!";
}

# name: tag_set_tagtitle_by_etag
# summary: set title for certain etag
# arguments:
#     $basemeta
#     $etag
#     $new_title: new title
# return: $etag
sub tag_set_tagtitle_by_etag {
    my ($self, $basemeta, $etag, $new_title) = @_;

    my $tag = $self->get_tag_from_etag($basemeta, $etag);

    $self->tag_set_tagtitle_by_tag($basemeta, $tag, $new_title);
}

# name: tag_list
# summary: list tags of entity
# arguments:
#     $basemeta
# return: ($tag, ...)
sub tag_list {
    my ($self, $basemeta) = @_;

    my (@tags);

    for my $tagdesc (bsd_glob($basemeta->{edir}.'/hwtagT*')){
        $tagdesc =~ s:^\Q$basemeta->{edir}/\E::;
        push @tags, $self->calc_tag_from_tagdesc($tagdesc);
    }

    return @tags;
}

# name: get_entity_number
# summary: get entity number of certain entity
# arguments:
#     $basemeta
# return: $entity_number
sub get_entity_number {
    my ($self, $basemeta) = @_;

    my $entity_number = abs2rel($basemeta->{edir},
                                $self->{config}{category}{$basemeta->{category}}{lib});
    $entity_number =~ s:/::g;

    return $entity_number;
}

# name: get_tag_from_etag
# summary: get tag from etag
# arguments:
#     $basemeta
#     $etag
# return: $tag
sub get_tag_from_etag {
    my ($self, $basemeta, $etag) = @_;
    my $etagdir = realpath(dirname($etag));

    my $category_config = $self->category_get_config($basemeta->{category});

    my $tag;
    if($etagdir eq $category_config->{export_title}){
        $tag = [undef, ['#title']];
    }elsif($etagdir eq $category_config->{export_untagged}){
        $tag = [undef, ['#untagged']];
    }else{
        my ($tagdir) = ($etagdir =~m :^\Q$category_config->{export}\E/(.*)$:);
        my $tagdesc_file = readlink_utf8($etag);
        die "Not an etag: $etag" unless $tagdesc_file;
        my $tagdesc = basename($tagdesc_file);
        $tag = $self->calc_tag_from_tagdesc($tagdesc);
    }

    return $tag;
}

# name: get_etag_from_tag
# summary: get etag from tag
# arguments:
#     $basemeta
#     $tag
# return: $etag
sub get_etag_from_tag {
    my ($self, $basemeta, $tag) = @_;
    my ($title, $taglink) = $self->check_tag($tag);

    $title ||= $self->entity_get_title($basemeta);
    my $category_config = $self->category_get_config($basemeta->{category});
    return catfile($category_config->{export}, @$taglink, $title);
}

# name: calc_tag_from_tagdesc
# summary: calculate tag from tagdesc
# arguments:
#     $tagdesc
# return: $tag
sub calc_tag_from_tagdesc {
    my ($self, $tagdesc) = @_;
    all_to_utf8($tagdesc);

    my ($tagdesc_base) = ($tagdesc =~ m:^\QhwtagT\E(.*):);
    die "Invalid tagdesc: $tagdesc" unless $tagdesc_base;

    my ($taglink_str) = ($tagdesc_base =~ m|^((?:[^!]+!?)+)|);
    die "Invalid tagdesc: $tagdesc" unless $taglink_str;
    my $taglink = [split /!+/, $taglink_str];

    my ($title) = ($tagdesc_base =~ m:^\Q$taglink_str\E!+(.*):);

    return [$title, $taglink];
}

# name: calc_tagdesc_from_tag
# summary: calculate tagdesc from tag
# arguments:
#     $tag
# return: $tagdesc
sub calc_tagdesc_from_tag {
    my ($self, $basemeta, $tag) = @_;
    my ($title, $taglink) = $self->check_tag($tag);

    my $default_title = $self->entity_get_title($basemeta);

    if ($title) {
        if ($title eq $default_title) {
            # reset title to default(undef)
            undef $title;
        }
    }

    my $tagdesc;
    $tagdesc ='hwtagT'.join('!', @$taglink);
    if ($title) {
        $tagdesc .= '!!'.$title;
    }

    return $tagdesc;
}

# name: is_autotag
# summary: Test if tag is autotag
# arguments:
#     $tag
# return: bool
sub is_autotag {
    my ($self, $tag) = @_;
    my ($title, $taglink) = $self->check_tag($tag);

    return $taglink->[0] =~ m:^#:;
}

# name: check_tag
# summary: Check if it's a valid tag
# arguments:
#     $tag
# return: ($title, $taglink)
sub check_tag {
    my ($self, $tag) = @_;

    my ($title, $taglink) = @$tag;
    die "Taglink should not be empty" unless @$taglink;
    all_to_utf8($title, @$taglink);

    return ($title, $taglink);
}

sub check_title {
    my ($self, $title) = @_;

    die "Title cannot contain '/' character" if $title =~ m:/:;
}
1;
