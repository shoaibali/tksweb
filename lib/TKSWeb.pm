package TKSWeb;

use Dancer ':syntax';
use Dancer::Plugin::DBIC;
use Dancer::Plugin::Passphrase;
use Dancer::Plugin::CDN;

use TKSWeb::Schema;

use DateTime;


our $VERSION = '0.1';


sub User      { schema->resultset('AppUser'); }
sub Activity  { schema->resultset('Activity'); }


##################################  Hooks  ###################################

hook before => sub {
    if( my $user = user_by_email( session('email') ) ) {
        var user => $user;
        return;
    }
    if( request->path !~ m{^/(login|logout)$} ) {
        return redirect "/login";
    }
};


hook before_template_render => sub {
    my $tokens = shift;

    my $vars = vars;
    $tokens->{user}  = $vars->{user};
    $tokens->{alert} = $vars->{alert};
    $tokens->{'cdn_url'}  = \&cdn_url;
};


################################  Helpers  ###################################

sub alert {
    my($message) = @_;
    var alert => $message;
}


################################  Routes  ####################################

get '/login' => sub {
    template 'login';
};


post '/login' => sub {
    my $user = get_user_from_login( param('email'), param('password') );
    if( $user ) {
        session email => $user->email;
        return redirect '/';
    }
    alert 'Invalid username or password';
    template 'login', { email => param('email') };
};


get '/logout' => sub {
    session->destroy;
    return redirect "/login";
};


get '/' => sub {
    my $monday = monday_of_week();
    return redirect "/week/$monday";
};


get qr{^/week/?(?<date>.*)$} => sub {
    my $date = captures->{date} // '';
    my $monday = monday_of_week( $date );
    return redirect "/week/$monday" if $date ne $monday;
    template 'week-view', {
        dates       => to_json( dates_for_weekview($monday) ),
        wr_systems  => to_json( wr_system_list() ),
        activities  => to_json( activities_for_week($monday) ),
    };
};


post '/activity' => sub {
    my $new = from_json( request->body );
    my $start_date_time = combine_date_time($new->{date}, $new->{start_time});
    my $activity = Activity->new({
        app_user_id   => var('user')->id,
        date_time     => $start_date_time,
        duration      => $new->{duration},
        wr_system_id  => $new->{wr_system_id},
        wr_number     => $new->{wr_number},
        description   => $new->{description},
    });
    $activity->insert;
    return to_json({ id => $activity->id });
};


put '/activity/:id' => sub {
    my $activity = activity_by_id( param('id') )
        or return status "not_found";
    my $new = from_json( request->body );
    my $start_date_time = combine_date_time($new->{date}, $new->{start_time});
    $activity->date_time($start_date_time);
    $activity->duration($new->{duration});
    $activity->wr_system_id($new->{wr_system_id});
    $activity->wr_number($new->{wr_number});
    $activity->description($new->{description});
    $activity->update;
    return to_json({ id => $activity->id });
};


del '/activity/:id' => sub {
    my $activity = activity_by_id( param('id') )
        or return status "not_found";
    $activity->delete;
    return to_json({status => 'deleted'});
};


############################  Support Routines  ##############################


sub get_user_from_login {
    my($email, $password) = @_;

    return unless $email;
    my $user = user_by_email( $email );
    if( $user  and  passphrase($password)->matches($user->password) ) {
        return $user;
    }
    return;
}


sub user_by_email {
    my $email = shift or return;
    return User->search({
        email   => lc( $email ),
        status  => 'active',
    })->first;
}


sub monday_of_week {
    my $dt = parse_date(shift) || DateTime->now;
    my $dow = $dt->dow;
    $dt->add( days => -1 * $dow + 1 ) if $dow != 1;
    return $dt->ymd;
}


sub dates_for_weekview {
    my $monday = parse_date(shift) or die "Date needed";
    return {
        next_monday => $monday->clone->add(days => 7)->ymd,
        last_monday => $monday->clone->add(days => -7)->ymd,
        week_dates  => days_of_week( $monday->clone ),
    };
}


sub days_of_week {
    my $dt = shift or die "Date needed";
    my @days;
    foreach (1..7) {
        push @days, $dt->ymd;
        $dt->add(days => 1);
    }
    return \@days;
}


sub wr_system_list {
    my @wr_systems;
    my $user = var 'user';
    my $rs = $user->wr_systems->search(
        {},
        {
            order_by => 'wr_system_id'
        }
    );
    while(my $wr_system = $rs->next) {
        my %sys = $wr_system->get_columns;
        push @wr_systems, \%sys;
    }
    return \@wr_systems;
}


sub activities_for_week {
    my $monday = parse_date(shift);
    my $start_date = $monday->ymd . ' 00:00:00';
    my $end_date   = $monday->add(days => 7)->ymd . ' 00:00:00';
    my @activities;
    my $user = var 'user';
    my $rs = $user->activities->search(
        {
            date_time => {
              -between => [ $start_date, $end_date ],
            },
        },
        {
            order_by => 'date_time'
        }
    );
    while(my $activity = $rs->next) {
        my %act = $activity->get_columns;
        $act{id} = delete $act{activity_id};
        my($date, $hours, $minutes)
            = (delete $act{date_time}) =~ m{(\d\d\d\d-\d\d-\d\d) (\d\d):(\d\d)};
        $act{date} = $date;
        $act{start_time} = $hours * 60 + $minutes;
        push @activities, \%act;
    }
    return \@activities;
}


sub parse_date {
    my $date = shift or return;
    return eval {
        $date =~ m{\A(\d\d\d\d)-(\d\d)-(\d\d)\z}
            and DateTime->new( year => $1, month => $2, day => $3 );
    };
}


sub activity_by_id {
    my $id = shift or return;
    return Activity->find({
        activity_id => $id,
        app_user_id => var('user')->id,
    });
}


sub combine_date_time {
    my($date, $minutes) = @_;

    my $hours = int( $minutes / 60 );
    $minutes  = $minutes % 60;
    return sprintf('%s %02u:%02u:00', $date, $hours, $minutes);
}


1;

