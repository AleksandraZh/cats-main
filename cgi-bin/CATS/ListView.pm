package CATS::ListView;

use strict;
use warnings;

use Encode ();
use List::Util qw(first min max);

use CATS::DB;
use CATS::Globals qw($is_jury $t);
use CATS::Messages qw(msg);
use CATS::Output qw(init_template);
use CATS::Settings qw($settings);
use CATS::Utils;
use CATS::Web qw(param url_param);

# Optimization: limit datasets by both maximum row count and maximum visible pages.
our $max_fetch_row_count = 1000;
my $visible_pages = 5;
my @display_rows = (10, 20, 30, 40, 50, 100, 300);

# Params: name, template, array_name, extra, extra_settings.
sub new {
    my ($class, %p) = @_;
    my $self = {
        name => $p{name} || die,
        template => $p{template} || die,
        array_name => $p{array_name} || $p{name},
        col_defs => undef,
        search => [],
        search_subqueries => [],
        db_searches => {},
        subqueries => {},
        enums => {},
        extra_settings => $p{extra_settings} || {},
    };
    bless $self, $class;
    $self->init_params;
    init_template($self->{template}, $p{extra});
    $self;
}

sub settings { $settings->{$_[0]->{name}} }
sub visible_cols { $_[0]->{visible_cols} }

sub init_params {
    my ($self) = @_;

    $_ && ref $_ eq 'HASH' or $_ = {} for $settings->{$self->{name}};
    my $s = $self->settings;
    $s->{search} ||= '';

    $s->{page} = url_param('page') if defined url_param('page');

    if (defined(my $search = Encode::decode_utf8 param('search'))) {
        if ($s->{search} ne $search) {
            $s->{search} = $search;
            $s->{page} = 0;
        }
    }
    my $ident = '[a-zA-Z][a-zA-Z0-9_]*';
    for (split /,\s*/, $s->{search}) {
        /^($ident)([!~^=><]?=|>|<|\?|!~)(.*)$/ ? push @{$self->{search}}, [ $1, $3, $2 ] :
        /^($ident)\((\d+)\)$/ ? push @{$self->{search_subqueries}}, [ $1, $2 ] :
        push @{$self->{search}}, [ '', $_, '' ];
    }

    if (defined url_param('sort')) {
        $s->{sort_by} = int(url_param('sort'));
        $s->{page} = 0;
    }

    if (defined url_param('sort_dir')) {
        $s->{sort_dir} = int(url_param('sort_dir'));
        $s->{page} = 0;
    }

    $self->{submitted} = param('visible') || param('do_search') ? 1 : 0;

    $self->{cols} =
        !$is_jury ? undef :
        # Has user just opened page or deselected all columns?
        $self->{submitted} || param('cols') ? [ param('cols') ] :
        !defined $s->{cols} ? undef :
        $s->{cols} eq '-' ? [] :
        [ split ',', $s->{cols} ];

    for (keys %{$self->{extra_settings}}) {
        my $v = param($_);
        $s->{$_} = $v if defined $v;
    }

    $s->{rows} ||= $display_rows[0];
    my $rows = param('rows') || 0;
    if ($rows > 0) {
        $s->{page} = 0 if $s->{rows} != $rows;
        $s->{rows} = $rows;
    }
}

sub regex_op {
    my ($op, $v) = @_;
    $op eq '=' || $op eq '==' ? "^\Q$v\E\$" :
    $op eq '!=' ? "^(?!\Q$v\E)\$" :
    $op eq '^=' ? "^\Q$v\E" :
    $op eq '~=' || $op eq '' ? "\Q$v\E" :
    $op eq '!~' ? "^(?!.*\Q$v\E)" :
    $op eq '?' ? "." :
    die "Unknown search op '$op'";
}

sub sql_op {
    my ($op, $v) = @_;
    $op eq '=' || $op eq '==' ? { '=', $v } :
    $op eq '!=' ? { '!=', $v } :
    $op eq '^=' ? { 'STARTS WITH', $v } :
    $op eq '~=' ? { 'LIKE', '%' . "$v%" } :
    $op eq '!~' ? { 'NOT LIKE', '%' . "$v%" } :
    $op eq '?' ? { '!=', undef, '!=', \q~''~ } :
    $op =~ /^>|>=|<|<=$/ ? { $op, $v } : # SQL-only for now.
    die "Unknown search op '$op'";
}

sub attach {
    my ($self, $url, $fetch_row, $sth, $p) = @_;

    my $s = $settings->{$self->{name}} ||= {};

    my ($row_count, $fetch_count, $page_count, @data) = (0, 0, 0);
    my $page = \$s->{page};
    $$page ||= 0;
    my $rows = $s->{rows} || 1;

    # <search> ::= <condition> { ',' <condition> }
    # <condition> ::= <value> | <field name> { '=' | '==' | '!=' | '^=' | '~=' | '!~' } <value> | <func>(<integer>)
    # Spaces are significant around values, but not around keys.
    # Values without field name are searched in all fields.
    # Different fields are AND'ed, multiple values of the same field are OR'ed.
    my %mask;
    for my $q (@{$self->{search}}) {
        my ($k, $v, $op) = @$q;
        $self->{db_searches}->{$k} or push @{$mask{$k} ||= []}, regex_op($op, $v);
    }
    for (values %mask) {
        my $s = join '|', @$_;
        $_ = qr/$s/i;
    }

    my ($row_keys, @unknown_searches);
    ROWS: while (my %row = $fetch_row->($sth)) {
        if (!$row_keys) {
            my @unknown_searches = grep $_ && !exists $row{$_}, sort keys %mask;
            delete $mask{$_} for @unknown_searches;
            msg(1143, join ', ', @unknown_searches) if @unknown_searches;
            $row_keys = [ sort grep !$self->{db_searches}->{$_} && !/^href_/, keys %row ];
        }
        msg(1166), last if ++$fetch_count > $max_fetch_row_count;
        last if $page_count > $$page + $visible_pages;
        for my $key (keys %mask) {
            defined first { ($_ // '') =~ $mask{$key} }
                ($key ? ($row{$key}) : values %row)
                or next ROWS;
        }
        ++$row_count;
        $page_count = int(($row_count + $rows - 1) / $rows);
        next if $page_count > $$page + 1;
        # Remember the last visible page data in case of a too large requested page number.
        @data = () if @data == $rows;
        push @data, \%row;
    }

    $$page = min(max($page_count - 1, 0), $$page);
    my $range_start = max($$page - int($visible_pages / 2), 0);
    my $range_end = min($range_start + $visible_pages - 1, $page_count - 1);

    my $pp = $p->{page_params} || {};
    my $page_extra_params = join '', map ";$_=" . CATS::Utils::escape_url($pp->{$_}),
        grep defined $pp->{$_}, sort keys %$pp;
    my $href_page = sub { "$url$page_extra_params;page=$_[0]" };
    my @pages = map {{
        page_number => $_ + 1,
        href_page => $href_page->($_),
        current_page => $_ == $$page
    }} $range_start..$range_end;

    $self->{visible_data} = \@data;
    $t->param(
        page => $$page, pages => \@pages, search => $s->{search},
        href_lv_action => "$url$page_extra_params",
        ($range_start > 0 ? (href_prev_pages => $href_page->($range_start - 1)) : ()),
        ($range_end < $page_count - 1 ? (href_next_pages => $href_page->($range_end + 1)) : ()),
        display_rows =>
            [ map { value => $_, text => $_, selected => $s->{rows} == $_ }, @display_rows ],
        $self->{array_name} => \@data,
        lv_settings => $self->settings,
    );
    if ($is_jury) {
        my @s = (
            map([ $_, 0 ], sort keys %{$self->{db_searches}}),
            map([ $_, 1 ], @$row_keys),
            map([ $_, 2 ], sort keys %{$self->{subqueries}}),
        );
        my $col_count = 4;
        my $row_count = int((@s + $col_count - 1) / $col_count);
        my $rows;
        for my $i (0 .. $row_count - 1) {
            for my $j (0 .. $col_count - 1) {
                push @{$rows->[$i]}, $s[$j * $row_count + $i];
            }
        }
        $t->param(search_hints => $rows);
        $t->param(search_enums => $self->{enums});
    }

    # Suppose that attach_listview call comes last, so we modify settings in-place.
    defined $s->{$_} && $s->{$_} ne '' or delete $s->{$_} for keys %$s;
}

sub visible_data { $_[0]->{visible_data} }

sub check_sortable_field {
    my ($self, $s) = @_;
    return defined $s->{sort_by} && $s->{sort_by} =~ /^\d+$/ && $self->{col_defs}->[$s->{sort_by}]
}

sub order_by {
    my ($self) = @_;
    my $s = $self->settings;
    $self->check_sortable_field($s) or return '';
    sprintf 'ORDER BY %s %s',
        $self->{col_defs}->[$s->{sort_by}]{order_by}, ($s->{sort_dir} ? 'DESC' : 'ASC');
}

sub where { $_[0]->{where} ||= $_[0]->make_where }

sub make_where {
    my ($self) = @_;
    my %result;
    for my $q (@{$self->{search}}) {
        my ($k, $v, $op) = @$q;
        my $f = $self->{db_searches}->{$k} or next;
        $v = $self->{enums}->{$k}->{$v} // $v;
        push @{$result{$f} //= []}, sql_op($op, $v);
    }
    my (@sq_list, @sq_unknown);
    for my $d (@{$self->{search_subqueries}}) {
        my ($name, $value) = @$d;
        my $sq = $self->{subqueries}->{$name}
            or push @sq_unknown, $name and next;
        my $msg_arg = $sq->{t} ? $dbh->selectrow_array($sq->{t}, undef, $value) : undef;
        msg($sq->{m}, $msg_arg) if $sq->{m};
        # SQL::Abstract uses double reference do designate subquery.
        push @sq_list, \[ $sq->{sq} => $value ];
    }
    msg(1143, join ',', @sq_unknown) if @sq_unknown;
    @sq_list ? { -and => [ \%result, @sq_list ] } : \%result;
}

sub where_cond {
    my ($self) = @_;
    my $where = $sql->where($self->where);
    $where =~ s/^\s*WHERE\s*//;
    $where;
}

sub maybe_where_cond {
    my ($self) = @_;
    %{$self->where} ? ' AND ' . $self->where_cond : '';
}

sub where_params {
    my ($self) = @_;
    my (undef, @params) = $sql->where($self->where);
    @params;
}

sub sort_in_memory {
    my ($self, $data) = @_;
    my $s = $self->settings;
    $self->check_sortable_field($s) or return $data;
    my $order_by = $self->{col_defs}->[$s->{sort_by}]{order_by};
    my $cmp = $s->{sort_dir} ?
        sub { $a->{$order_by} cmp $b->{$order_by} } :
        sub { $b->{$order_by} cmp $a->{$order_by} };
    [ sort $cmp @$data ];
}

sub add_db_search {
    my ($self, $k, $v) = @_;
    $self->{db_searches}->{$k} and die "Duplicate search: $k";
    $self->{db_searches}->{$k} = $v;
}

sub define_db_searches {
    my ($self, $db_searches) = @_;
    if (ref $db_searches eq 'ARRAY') {
        for (@$db_searches) {
            $self->add_db_search((m/\.(.+)$/ ? $1 : $_), $_);
        }
    }
    elsif (ref $db_searches eq 'HASH') {
        for (keys %$db_searches) {
            $self->add_db_search($_, $db_searches->{$_});
        }
    }
    else {
        die;
    }
}

sub define_subqueries {
    my ($self, $subqueries) = @_;
    for my $k (keys %$subqueries) {
        $self->{subqueries}->{$k} and die "Duplicate subquery: $k";
        $self->{subqueries}->{$k} =
            ref $subqueries->{$k} ? $subqueries->{$k} : { sq => $subqueries->{$k} };
    }
}

sub define_enums {
    my ($self, $enums) = @_;
    for my $k (keys %$enums) {
        die if $self->{enums}->{$k};
        $self->{enums}->{$k} = $enums->{$k};
    }
}

sub define_columns {
    my ($self, $url, $default_by, $default_dir, $col_defs) = @_;

    my $s = $self->settings;
    $s->{sort_by} = $default_by if !defined $s->{sort_by} || $s->{sort_by} eq '';
    $s->{sort_dir} = $default_dir if !defined $s->{sort_dir} || $s->{sort_dir} eq '';

    $self->{col_defs} = $col_defs or die;

    my $init = defined $self->{cols} ? 0 : 1;
    $self->{visible_cols} = { map { $_->{col} => $init } grep $_->{col}, @$col_defs };
    if (!$init) {
        $self->{visible_cols}->{$_} = 1 for @{$self->{cols}};
    }

    for my $i (0 .. $#$col_defs) {
        my $def = $col_defs->[$i];
        $def->{visible} = !$def->{col} || $self->{visible_cols}->{$def->{col}} or next;
        my $dir = 0;
        if ($s->{sort_by} eq $i) {
            $def->{'sort_' . ($s->{sort_dir} ? 'down' : 'up')} = 1;
            $dir = 1 - $s->{sort_dir};
        }
        $def->{href_sort} = "$url;sort=$i;sort_dir=$dir";
    }
    if (grep !$_->{visible}, @$col_defs) {
        $s->{cols} = join(',', map { $_->{visible} && $_->{col} ? $_->{col} : () } @$col_defs) || '-';
    }
    else {
        delete $s->{cols};
    }

    $t->param(
        col_defs => $col_defs,
        can_change_cols => ($is_jury && scalar %{$self->{visible_cols}}),
        visible_cols => $self->{visible_cols});
}

sub extract_search_value {
    my ($self, $name) = @_;
    for (my $i = 0; $i < @{$self->{search}}; ++$i) {
        my ($k, $v) = @{$self->{search}->[$i]};
        $k eq $name or next;
        splice @{$self->{search}}, $i, 1;
        return $self->{enums}->{$k}->{$v} // $v;
    }
    undef;
}

sub search_subquery_value {
    my ($self, $name) = @_;
    $_->[0] eq $name and return $_->[1] for @{$self->{search_subqueries}};
    undef;
}

sub searches_subset_of {
    my ($self, $set) = @_;
    for (@{$self->{search}}, @{$self->{search_subqueries}}) {
        $set->{$_->[0]} or return 0;
    }
    1;
}

1;
