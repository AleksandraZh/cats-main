package CATS::UI::RunDetails;

use strict;
use warnings;

use Algorithm::Diff;
use List::Util qw(max);
use JSON::XS;

use CATS::BinaryFile;
use CATS::Constants;
use CATS::DB;
use CATS::DevEnv;
use CATS::Globals qw($cid $contest $is_jury $is_root $sid $t $uid $user);
use CATS::IP;
use CATS::JudgeDB;
use CATS::Messages qw(msg res_str);
use CATS::Output qw(init_template downloads_path downloads_url url_f);
use CATS::Problem::Utils;
use CATS::RankTable;
use CATS::Request;
use CATS::ReqDetails qw(
    get_contest_info
    get_contest_tests
    get_log_dump
    get_req_details
    get_sources_info
    get_test_data
    sources_info_param
    source_links);
use CATS::Settings qw($settings);
use CATS::Testset;
use CATS::Utils;
use CATS::Verdicts;

sub get_run_info {
    my ($p, $contest, $req) = @_;
    my $points = $contest->{points};

    my $last_test = 0;
    my $total_points = 0;
    my $all_testsets = CATS::Testset::get_all_testsets($dbh, $req->{problem_id});
    my %testset = CATS::Testset::get_testset($dbh, 'reqs', $req->{req_id});
    $contest->{show_points} ||= 0 < grep $_, values %testset;
    my (%run_details, %used_testsets, %accepted_tests, %accepted_deps);

    my $comment_enc = $p->{comment_enc};

    my @resources = qw(time_used memory_used disk_used);
    my $rd_fields = join ', ', (
         qw(test_rank result points),
         ($contest->{show_test_resources} ? @resources : ()),
         ($contest->{show_checker_comment} || $req->{partial_checker} ? qw(checker_comment) : ()),
    );

    for my $row (get_req_details($contest, $req, $rd_fields, \%accepted_tests)) {
        $_ and $_ = sprintf('%.3g', $_) for $row->{time_used};
        if ($contest->{show_checker_comment}) {
            my $d = $row->{checker_comment} || '';
            # Comment may be non-well-formed utf8
            $row->{checker_comment} = Encode::decode($comment_enc, $d, Encode::FB_QUIET);
            $row->{checker_comment} .= '...' if $d ne '';
        }

        $last_test = $row->{test_rank};
        my $p = $row->{is_accepted} ? $row->{points} || $points->[$row->{test_rank} - 1] || 0 : 0;
        if (my $ts = $row->{ts} = $testset{$last_test}) {
            $used_testsets{$ts->{name}} = $ts;
            $ts->{accepted_count} //= 0;
            push @{$ts->{list} ||= []}, $last_test;
            if (CATS::RankTable::dependencies_accepted($all_testsets, $ts, \%accepted_tests, \%accepted_deps)) {
                $ts->{accepted_count} += $row->{is_accepted};
                if (defined $ts->{points}) {
                    $total_points += $ts->{earned_points} = $ts->{points}
                        if $ts->{accepted_count} == $ts->{test_count};
                }
                else {
                    $total_points += $p;
                    $ts->{earned_points} += $p;
                }
            }
            else {
                $p = 'X';
            }
            if ($ts->{hide_details} && $contest->{hide_testset_details}) {
                $row->{is_hidden} = 1;
            }
            if (defined $ts->{points} || $ts->{hide_details} && $contest->{hide_testset_details}) {
                $p = '';
            }
            $p .= " => $ts->{name}";
        }
        elsif ($row->{is_accepted} && $req->{partial_checker}) {
            $total_points += $p = CATS::RankTable::get_partial_points($row, $p);
        }
        else {
            $total_points += $p;
        }
        $run_details{$last_test} = {
            %$row, points => $p,
            short_state => $row->{is_hidden} ? '' : $CATS::Verdicts::state_to_name->{$row->{result}},
        };
    }

    # Output 'not processed' for tests we do not plan to run, but must still display.
    if ($contest->{show_all_tests} && !$contest->{run_all_tests}) {
        $last_test = @$points;
    }
    if ($contest->{hide_testset_details}) {
        for (values %used_testsets) {
            $_->{accepted_count} = '?'
                if $_->{hide_details} && $_->{accepted_count} != $_->{test_count};
        }
    }

    my $run_row = sub {
        my ($rank) = @_;
        return $run_details{$rank} if exists $run_details{$rank};
        return () unless $contest->{show_all_tests};
        my %r = (test_rank => $rank, ts => $testset{$rank});
        $r{short_state} = exists $testset{$rank} ? 'NP' : 'NT';
        return \%r;
    };

    my $visualizers = $dbh->selectall_arrayref(q~
        SELECT PS.id, PS.name
        FROM problem_sources PS
        INNER JOIN problems P ON PS.problem_id = P.id
        INNER JOIN reqs R ON R.problem_id = P.id
        WHERE R.id = ? AND PS.stype = ?~, { Slice => {} },
        $req->{req_id}, $cats::visualizer);

    my %outputs = map { $_->{test_rank} => $_->{output} } @{$dbh->selectall_arrayref(qq~
        SELECT SUBSTRING(SO.output FROM 1 FOR $cats::test_file_cut + 1) as output, SO.test_rank
        FROM solution_output SO WHERE SO.req_id = ? AND SO.test_rank <= ?~, { Slice => {} },
        $req->{req_id}, $last_test)};

    my $maximums = { map { $_ => 0 } @resources };
    my $add_testdata = sub {
        my ($row) = @_ or return ();
        $contest->{show_test_data} or return $row;
        my $t = $contest->{tests}->[$row->{test_rank} - 1] or return $row;
        $t->{param} //= '';
        $row->{input_gen_params} = CATS::Problem::Utils::gen_group_text($t);
        $row->{input_data} =
            defined $t->{input} ? $t->{input} : $row->{input_gen_params};
        $row->{input_data_cut} = length($t->{input} || '') > $cats::test_file_cut;
        $row->{answer_data} = $t->{answer};
        $row->{answer_data_cut} = length($t->{answer} || '') > $cats::test_file_cut;
        $row->{visualize_test_hrefs} =
            defined $t->{input} ? [ map +{
                href => url_f('visualize_test', rid => $req->{req_id}, test_rank => $row->{test_rank}, vid => $_->{id}),
                name => $_->{name}
            }, @$visualizers ] : [];
        $maximums->{$_} = max($maximums->{$_}, $row->{$_} // 0) for @resources;
        $row->{output_data} = $outputs{$row->{test_rank}};
        $row->{output_data_cut} = length($row->{output_data} || '') > $cats::test_file_cut;
        $row->{view_test_details_href} = url_f('view_test_details', rid => $req->{req_id}, test_rank => $row->{test_rank});
        $row;
    };
    if (
        $contest->{show_points} && $contest->{points} &&
        # Do not cache incomplete points to avoid messing up RankTable cache.
        $req->{state} > $cats::request_processed &&
        (!defined $req->{points} || $req->{points} != $total_points)
    ) {
        $req->{points} = $total_points;
        eval {
            $req->{needs_commit} = $dbh->do(q~
                UPDATE reqs SET points = ? WHERE id = ? AND points IS DISTINCT FROM ?~, undef,
                $req->{points}, $req->{req_id}, $req->{points});
            1;
        } or CATS::DB::catch_deadlock_error("get_run_info $req->{req_id}");
    }

    return {
        %$contest,
        id => $req->{req_id},
        total_points => $total_points,
        run_details => [ map $add_testdata->($run_row->($_)), 1..$last_test ],
        maximums => $maximums,
        testsets => [ sort { $a->{list}[0] <=> $b->{list}[0] } values %used_testsets ],
        accepted_deps => \%accepted_deps,
        has_depends_on => 0 < grep($_->{depends_on}, values %used_testsets),
        has_visualizer => @$visualizers > 0,
        has_output => $req->{save_output_prefix},
    };
}

sub _get_compilation_error {
    my ($logs, $st) = @_;

    my $section = $st == $cats::st_compilation_error ? $cats::log_section_compile : $cats::log_section_lint;
    my $compilation_error_re = qr/
        \Q$cats::log_section_start_prefix$section\E
        (.*)
        \Q$cats::log_section_end_prefix$section\E
        /sx;
    for (@$logs) {
        $_->{dump} or next;
        my ($error) = $_->{dump} =~ $compilation_error_re;
        return $error if $error;
    }
    undef;
}

sub run_details_frame {
    my ($p) = @_;
    init_template($p, 'run_details.html.tt');

    my $sources_info = get_sources_info($p, request_id => $p->{rid}, partial_checker => 1) or return;
    my @runs;
    my $contest_cache = {};

    my $needs_commit;
    for (@$sources_info) {
        source_links($p, $_);
        my $st = $_->{state};
        if ($st == $cats::st_compilation_error || $st == $cats::st_lint_error) {
            my $logs = get_log_dump({ req_id => $_->{req_id} });
            push @runs, { compiler_output => _get_compilation_error($logs, $st) };
            next;
        }
        my $c = get_contest_tests(get_contest_info($p, $_, $contest_cache), $_->{problem_id});
        push @runs, get_run_info($p, $c, $_);
        $needs_commit ||= $_->{needs_commit};
    }
    $dbh->commit if $needs_commit;
    sources_info_param($sources_info);
    $t->param(runs => \@runs,
        display_input => $settings->{display_input},
        display_answer => $settings->{display_input},
        display_output => $settings->{display_input}, #TODO: Add this params to settings
    );
}

sub save_visualizer {
    my ($data, $lfname, $pid, $hash) = @_;

    CATS::Problem::Utils::ensure_problem_hash($pid, \$hash, 1);

    my $fname = "vis/${hash}_$lfname";
    my $fpath = downloads_path . $fname;
    -f $fpath or CATS::BinaryFile::save($fpath, $data);
    return downloads_url . $fname;
}

sub visualize_test_frame {
    my ($p) = @_;
    init_template($p, 'visualize_test.html.tt');

    $uid or return;
    my $rid = $p->{rid} or return;
    my $vid = $p->{vid} or return;
    my $test_rank = $p->{test_rank} or return;

    my $sources_info = get_sources_info($p,
        request_id => $rid, extra_params => [ test_rank => $test_rank, vid => $p->{vid} ]);
    source_links($p, $sources_info);
    sources_info_param([ $sources_info ]);

    my $ci = get_contest_info($p, $sources_info, {});
    $ci->{show_test_data} or return;

    my @tests = get_req_details($ci, $sources_info, 'test_rank, result', {});
    grep $_->{test_rank} == $test_rank, @tests or return;

    my $visualizer = $dbh->selectrow_hashref(q~
        SELECT PS.name, PS.src, PS.fname, P.id AS problem_id, P.hash
        FROM problem_sources PS
        INNER JOIN problems P ON PS.problem_id = P.id
        INNER JOIN reqs R ON R.problem_id = P.id
        WHERE R.id = ? AND PS.id = ? AND PS.stype = ?~, { Slice => {} },
        $rid, $vid, $cats::visualizer) or return;

    my @imports_js = (@{$dbh->selectall_arrayref(q~
        SELECT PS.src, PS.fname, PS.problem_id, P.hash
        FROM problem_sources_import PSI
        INNER JOIN problem_sources PS ON PS.guid = PSI.guid
        INNER JOIN problems P ON P.id = PS.problem_id
        WHERE PSI.problem_id = ? AND PS.stype = ?~, { Slice => {} },
        $visualizer->{problem_id}, $cats::visualizer_module)}, $visualizer);

    my $test_data = get_test_data($p) or return;

    @{$test_data}{qw(output output_size)} = $dbh->selectrow_array(q~
        SELECT SO.output, SO.output_size
        FROM solution_output SO
        WHERE SO.req_id = ? AND SO.test_rank = ?~, undef,
        $rid, $test_rank);

    my $vhref = sub { url_f('visualize_test', rid => $rid, test_rank => $_[0], vid => $vid) };

    $t->param(
        vis_scripts => [
            map save_visualizer($_->{src}, $_->{fname}, $_->{problem_id}, $_->{hash}), @imports_js
        ],
        test_data_json => JSON::XS->new->utf8->indent(2)->canonical->encode($test_data),
        visualizer => $visualizer,
        href_prev_pages => $test_rank > $tests[0]->{test_rank} ? $vhref->($test_rank - 1) : undef,
        href_next_pages => $test_rank < $tests[-1]->{test_rank} ? $vhref->($test_rank + 1) : undef,
        test_ranks => [
            map +{
                page_number => $_->{test_rank},
                href_page => $vhref->($_->{test_rank}),
                current_page => $_->{test_rank} == $test_rank,
                short_verdict => $CATS::Verdicts::state_to_name->{$_->{result}},
            }, @tests
        ],
    );
}

sub view_source_frame {
    my ($p) = @_;
    init_template($p, 'view_source.html.tt');
    $p->{rid} or return;
    my $sources_info = get_sources_info($p, request_id => $p->{rid}, get_source => 1, encode_source => 1);
    $sources_info or return;

    if ($p->{submit}) {
        $p->{problem_id} = $dbh->selectrow_array(q~
            SELECT problem_id FROM reqs WHERE id = ?~,
            undef, $p->{rid});
        $p->{source_text} = '' if $p->{source};
        my $rid = CATS::Problem::Submit::problems_submit($p);
        $rid and return $p->redirect(url_f 'view_source', rid => $rid, submitted => 1);
    }
    elsif ($sources_info->{is_jury} && $p->{replace}) {
        my $u;
        my $src = $p->{source} ? $p->{source}->content // die : $p->{source_text};
        if (defined $src && $src ne '') {
            $u->{src} = $src;
            $u->{hash} = CATS::Utils::source_hash($src);
        }
        my $de_bitmap;
        if ($p->{de_id} && $p->{de_id} != $sources_info->{de_id}) {
            $u->{de_id} = $p->{de_id};
            $de_bitmap = [ CATS::DevEnv->new(CATS::JudgeDB::get_DEs())->bitmap_by_ids($p->{de_id}) ];
        }
        if ($u) {
            CATS::Request::update_source($sources_info->{req_id}, $u, $de_bitmap);
            $dbh->commit;
            $sources_info = get_sources_info($p,
                request_id => $p->{rid}, get_source => 1, encode_source => 1);
        }
    }
    else {
        msg(1014) if $p->{submitted};
    }
    source_links($p, $sources_info);
    sources_info_param([ $sources_info ]);
    @{$sources_info->{elements}} <= 1 or return msg(1155);

    if ($sources_info->{file_name} =~ m/\.zip$/) {
        $sources_info->{src} = sprintf 'ZIP, %d bytes', length ($sources_info->{src});
    }
    if (my $r = $sources_info->{err_regexp}) {
        my (undef, undef, $file_name) = CATS::Utils::split_fname($sources_info->{file_name});
        CATS::Utils::sanitize_file_name($file_name);
        $file_name =~ s/([^a-zA-Z0-9_])/\\$1/g;
        for (split ' ', $r) {
            s/~FILE~/$file_name/;
            s/~LINE~/(\\d+)/;
            s/~POS~/\\d+/;
            push @{$sources_info->{err_regexp_js}}, "/$_/";
        }
    }
    $sources_info->{syntax} = $p->{syntax} if $p->{syntax};
    $sources_info->{src_lines} = [ map {}, split("\n", $sources_info->{src}) ];
    my $st = $sources_info->{state};
    if ($st == $cats::st_compilation_error || $st == $cats::st_lint_error) {
        my $logs = get_log_dump({ req_id => $sources_info->{req_id} });
        $sources_info->{compiler_output} = _get_compilation_error($logs, $st)
    }

    my $can_submit = $is_jury ||
            $user->{is_participant} &&
            ($user->{is_virtual} || !$contest->has_finished($user->{diff_time} + $user->{ext_time}));

    if ($sources_info->{is_jury} || $can_submit) {
        my $de_list = CATS::DevEnv->new(CATS::JudgeDB::get_DEs({ active_only => 1, fields => 'syntax' }));
        if ($p->{de_id}) {
            $sources_info->{de_id} = $p->{de_id};
            $sources_info->{de_name} = $de_list->by_id($p->{de_id})->{description};
        }
        $t->param(de_list => [
            map {
                de_id => $_->{id},
                de_name => $_->{description},
                selected => $_->{id} == $sources_info->{de_id},
                syntax => $_->{syntax},
            }, @{$de_list->des}
        ]);
    }
    $t->param(
        source_width => $settings->{source_width} // 90,
        can_submit => $can_submit,
        href_action => url_f('view_source', rid => $p->{rid}),
    );
}

sub download_source_frame {
    my ($p) = @_;
    $p->{rid} or return;
    my $si = get_sources_info($p, request_id => $p->{rid}, get_source => 1, encode_source => 1);

    unless ($si) {
        init_template($p, 'view_source.html.tt');
        return;
    }

    $si->{file_name} =~ m/\.([^.]+)$/;
    my $ext = $1 || 'unknown';
    $p->print_file(
        ($ext eq 'zip' ?
            (content_type => 'application/zip') :
            (content_type => 'text/plain', charset => 'UTF-8')),
        file_name => "$si->{req_id}.$ext",
        content => Encode::encode_utf8($si->{src}));
}

sub view_test_details_frame {
    my ($p) = @_;
    init_template($p, 'view_test_details.html.tt');

    $p->{rid} or return;
    $p->{test_rank} //= 1;

    my $sources_info = get_sources_info($p,
        request_id => $p->{rid}, extra_params => [ test_rank => $p->{test_rank} ]) or return;

    my $ci = get_contest_info($p, $sources_info, {});
    $ci->{show_test_data} or return;

    my $output_data;
    if ($is_jury && $p->{delete_request_outputs}) {
        $dbh->do(q~
            DELETE FROM solution_output SO WHERE SO.req_id = ?~, undef,
            $p->{rid});
        $dbh->commit;
    } elsif($is_jury && $p->{delete_test_output}) {
        $dbh->do(q~
            DELETE FROM solution_output SO WHERE SO.req_id = ? AND SO.test_rank = ?~, undef,
            $p->{rid}, $p->{test_rank});
        $dbh->commit;
    } else {
        $output_data = $dbh->selectrow_hashref(q~
            SELECT SO.output, SO.output_size FROM solution_output SO
            WHERE SO.req_id = ? AND SO.test_rank = ?~, { Slice => {} },
            $p->{rid}, $p->{test_rank});
    }

    my $save_prefix_lengths = $dbh->selectrow_hashref(q~
        SELECT
            p.save_input_prefix as input_prefix,
            p.save_answer_prefix as answer_prefix,
            p.save_output_prefix as output_prefix
        FROM problems P
            INNER JOIN reqs R ON R.problem_id = P.id
        WHERE R.id = ?~, { Slice => {} },
        $p->{rid});

    my $test_data = get_test_data($p);

    my $tdhref = sub { url_f('view_test_details', rid => $p->{rid}, test_rank => $_[0]) };

    my @tests = get_req_details($ci, $sources_info, 'test_rank, result', {});
    grep $_->{test_rank} == $p->{test_rank}, @tests or return;

    source_links($p, $sources_info);
    sources_info_param([ $sources_info ]);
    $t->param(
        output_data => $output_data,
        test_data => $test_data,
        save_prefix_lengths => $save_prefix_lengths,
        href_prev_pages => $p->{test_rank} > $tests[0]->{test_rank} ? $tdhref->($p->{test_rank} - 1) : undef,
        href_next_pages => $p->{test_rank} < $tests[-1]->{test_rank} ? $tdhref->($p->{test_rank} + 1) : undef,
        test_ranks => [
            map +{
                page_number => $_->{test_rank},
                href_page => $tdhref->($_->{test_rank}),
                current_page => $_->{test_rank} == $p->{test_rank},
                short_verdict => $CATS::Verdicts::state_to_name->{$_->{result}},
            }, @tests
        ],
    );
}

sub run_log_frame {
    my ($p) = @_;
    init_template($p, 'run_log.html.tt');
    my $rid = $p->{rid} or return;

    my $si = get_sources_info($p, request_id => $rid)
        or return;
    $si->{is_jury} or return;

    source_links($p, $si);
    sources_info_param([ $si ]);

    CATS::Request::delete_logs({ req_id => $rid }) if $p->{delete_log};
    CATS::Request::delete_jobs({ req_id => $rid }) if $p->{delete_jobs};

    $t->param(
        href_jobs => url_f('jobs', search => "req_id=$rid"),
        logs => get_log_dump({ req_id => $rid, parent_id => undef }),
        job_enums => $CATS::Globals::jobs,
    );
}

sub diff_runs_frame {
    my ($p) = @_;
    init_template($p, 'diff_runs.html.tt');
    $p->{r1} && $p->{r2} or return;

    my $si = get_sources_info($p,
        request_id => [ $p->{r1}, $p->{r2} ], get_source => 1, encode_source => 1) or return;
    @$si == 2 or return;

    source_links($p, $_) for @$si;
    sources_info_param($si);

    return msg(1155) if grep @{$_->{elements}} > 1, @$si;

    for my $info (@$si) {
        $info->{lines} = [ split "\n", $info->{src} ];
        s/\s*$// for @{$info->{lines}};
    }

    my @diff;

    my $SL = sub { $si->[$_[0]]->{lines}->[$_[1]] || '' };

    my $match = sub { push @diff, { class => 'diff_both', line => $SL->(0, $_[0]) }; };
    my $only_a = sub { push @diff, { class => 'diff_only_a', line => $SL->(0, $_[0]) }; };
    my $only_b = sub { push @diff, { class => 'diff_only_b', line => $SL->(1, $_[1]) }; };

    Algorithm::Diff::traverse_sequences(
        $si->[0]->{lines},
        $si->[1]->{lines},
        {
            MATCH     => $match,  # callback on identical lines
            DISCARD_A => $only_a, # callback on A-only
            DISCARD_B => $only_b, # callback on B-only
        }
    );

    $t->param(diff_lines => \@diff);
}

sub get_last_verdicts_api {
    my ($p) = @_;
    $uid && @{$p->{problem_ids}} or return $p->print_json->({});
    my $state_sth = $dbh->prepare(q~
        SELECT state, failed_test, id FROM reqs
        WHERE contest_id = ? AND account_id = ? AND problem_id = ?
        ORDER BY submit_time DESC ROWS 1~);
    my $result = {};
    for (@{$p->{problem_ids}}) {
        $state_sth->execute($cid, $uid, $_);
        my ($state, $failed_test, $rid) = $state_sth->fetchrow_array;
        $state_sth->finish;
        defined $state or next;
        $result->{$_} = [
            $CATS::Verdicts::state_to_name->{$state}, $failed_test,
            url_f('run_details', rid => $rid) ]
    }
    $p->print_json($result);
}

sub _get_request_state {
    my ($p) = @_;
    $uid && @{$p->{req_ids}} or return ();
    my $result = $dbh->selectall_arrayref(_u $sql->select(
        'reqs', 'id, state, failed_test, account_id, contest_id',
        { id => $p->{req_ids} }));
    return @$result if $is_root;
    my %contest_ids;
    for (@$result) {
        if ($_->{account_id} == $uid || $_->{contest_id} == $cid && $is_jury) {
            $_->{ok} = 1;
        }
        else {
            $contest_ids{$_->{id}} = 1;
        }
    }
    my ($stmt, @bind) = $sql->select(
        'contest_accounts', 'contest_id, is_jury',
        { contest_id => [ keys %contest_ids ], account_id => $uid });
    my $jury_in_contest = $dbh->selectall_hashref($stmt, 'contest_id', undef, @bind);
    grep $_->{ok} || $jury_in_contest->{$_->{contest_id}}->{is_jury}, @$result;
}

sub get_request_state_api {
    my ($p) = @_;
    $p->print_json([ map {
        id => $_->{id},
        verdict => $CATS::Verdicts::state_to_name->{$_->{state}},
        failed_test => $_->{failed_test},
        np => $_->{state} < $cats::request_processed,
    }, _get_request_state($p) ]);
}

1;
