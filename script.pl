#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Net::Twitter::Lite::WithAPIv1_1;
use Mojolicious::Lite;
use File::Basename 'basename';
use File::Path 'mkpath';
use Config::Pit;
use Image::Magick;
use Encode;

# Config::Pit
my $config = Config::Pit::get("twimage");

my $consumer_key    = $config->{consumer_key};
my $consumer_secret = $config->{consumer_secret};

app->config(
    hypnotoad => {
        listen  => [ 'http://*:' . $config->{port} ],
        workers => 2,
    },
);

app->hook(
    'before_dispatch' => sub {
        my $self = shift;
        if ($self->req->headers->header('X-Forwarded-Host')) {

            #Proxy Path setting
            my $path = shift @{ $self->req->url->path->parts };
            push @{ $self->req->url->base->path->parts }, $path;
        }
    }
);

my $THIS_SITE = "https://retrorocket.biz/twimage";

# Image base URL
my $IMAGE_BASE = app->home . '/assets/images';
my $IMAGE_DIR  = $IMAGE_BASE;

# Create directory if not exists
unless (-d $IMAGE_DIR) {
    mkpath $IMAGE_DIR or die "Cannot create dirctory: $IMAGE_DIR";
}

get '/auth' => sub {
    my $self = shift;

    if ($self->param("session")) {
        $self->session(flag => $self->param("session"));
    }

    my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
        consumer_key    => $consumer_key,
        consumer_secret => $consumer_secret,
        ssl             => 1
    );

    my $cb_url = $self->url_for('auth_cb')->to_abs->scheme('https');
    my $url    = $nt->get_authentication_url(callback => $cb_url);

    $self->session(token        => $nt->request_token);
    $self->session(token_secret => $nt->request_token_secret);

    $self->redirect_to($url);
} => 'auth';

get '/auth_cb' => sub {
    my $self         = shift;
    my $verifier     = $self->param('oauth_verifier') || '';
    my $token        = $self->session('token')        || '';
    my $token_secret = $self->session('token_secret') || '';

    my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
        consumer_key    => $consumer_key,
        consumer_secret => $consumer_secret,
        ssl             => 1
    );

    $nt->request_token($token);
    $nt->request_token_secret($token_secret);

    # Access token取得
    my ($access_token, $access_token_secret, $user_id, $screen_name) = $nt->request_access_token(verifier => $verifier);

    # Sessionに格納
    $self->session(access_token        => $access_token);
    $self->session(access_token_secret => $access_token_secret);
    $self->session(screen_name         => $screen_name);

    $self->redirect_to($self->url_for('index')->to_abs->scheme('https'));

    #$self->redirect_to( 'index' );
} => 'auth_cb';

# Display top page
get '/' => sub {
    my $self = shift;

    my $access_token        = $self->session('access_token')        || '';
    my $access_token_secret = $self->session('access_token_secret') || '';

    # セッションにaccess_tokenが残ってなければ再認証
    return $self->redirect_to($THIS_SITE)
      unless ($access_token && $access_token_secret);

} => 'index';

# Upload image file
post '/upload' => sub {
    my $self = shift;

    my $access_token        = $self->session('access_token')        || '';
    my $access_token_secret = $self->session('access_token_secret') || '';
    my $screen_name         = $self->session('screen_name')         || '';

    # セッションにaccess_tokenが残ってなければ再認証
    return $self->redirect_to($THIS_SITE)
      unless ($access_token && $access_token_secret);

    my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
        consumer_key    => $consumer_key,
        consumer_secret => $consumer_secret,
        ssl             => 1
    );

    $nt->access_token($access_token);
    $nt->access_token_secret($access_token_secret);

    # Uploaded image(Mojo::Upload object)
    my $image  = $self->req->upload('image');
    my $status = $self->param('status');
    $status = encode('UTF-8', $status);

    # Not upload
    if ($image->size <= 0) {
        return $self->render(
            template => 'error',
            message  => "ファイルサイズが0byte以下です。"
        );
    }
    elsif ($image->size >= 5 * 1024 * 1024) {
        return $self->render(
            template => 'error',
            message  => "ファイルサイズが5MB以上です。"
        );
    }

    # 拡張子つけてアップロードしてくれない人が多すぎるのでこちらでチェックせずTwitter側にチェックさせることにした。
    my $image_file = "$IMAGE_DIR/" . $screen_name;

    # If file is exists, unlink file
    while (-f $image_file) {
        unlink $image_file;
    }

    #$image_file = uri_escape( $image_file );
    # Save to file
    $image->move_to($image_file);

    #PNG変換モード
    my $img = Image::Magick->new;
    $img->Read($image_file);
    $img->Set(alpha => 'On');
    my @pixels = $img->GetPixel(x => 0, y => 0);
    if ($pixels[3] >= 1) {
        $pixels[3] = 0.998;
    }
    $img->SetPixel(x => 0, y => 0, color => \@pixels);
    binmode(STDOUT);
    $img->Write("PNG32:" . $image_file);
    undef $img;

    $self->stash('name' => $screen_name);

    my $error_occured = "false";

    eval { $nt->update_with_media($status, [$image_file]); };
    if ($@) {
        $error_occured = $@;
    }
    my $result_message = "ファイルをアップロードしました";
    if ($error_occured ne "false") {
        $result_message = "ファイルのアップロードに失敗しました（Twitter Error：" . $error_occured . "）";
    }
    $self->stash('message' => $result_message);

    #ファイル削除
    undef $image;
    undef $nt;
    unlink $image_file;

    return 1;

} => 'upload';

get '/upload' => sub {
    my $self = shift;
    $self->redirect_to($self->url_for('index')->to_abs->scheme('https'));
} => 'get_upload';

# Session削除
get '/logout' => sub {
    my $self = shift;
    $self->session(expires => 1);

    #$self->render;
} => 'logout';

app->sessions->secure(1);
app->sessions->cookie_name($config->{session_name});
app->secrets([ $config->{secure} ]);  # セッション管理のために付けておく
app->start;
