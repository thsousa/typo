require File.dirname(__FILE__) + '/../test_helper'
require 'articles_controller'
require 'dns_mock'
require 'http_mock'

require 'content'

#
# Re-raise errors caught by the controller.
class ArticlesController; def rescue_action(e) raise e end; end

class Content
  def self.find_last_posted
    self.find(:first, :conditions => ['created_at < ?', Time.now],
              :order => 'created_at desc')
  end
end

class ArticlesControllerTest < Test::Unit::TestCase
  fixtures :contents, :feedback, :categories, :blogs, :users, :categorizations, :text_filters, :articles_tags, :tags
  include ArticlesHelper

  def setup
    @controller = ArticlesController.new
    @request, @response = ActionController::TestRequest.new, ActionController::TestResponse.new

    Article.create!(:title => "News from the future!",
                    :body => "The future is cool!",
                    :keywords => "future",
                    :created_at => Time.now + 12.minutes)
    Sidebar.delete_all
  end

  def show_article(article)
    get :show, article_params(article)
  end

  def post_comment(article, comment_params = {})
    with_options(article_params(article)) do |send|
      send.post :comment, :comment => comment_params
    end
  end

  def article_params(article)
    [:year, :month, :day, :id].zip(article.param_array).inject({}) do |init, (k,v)|
      init.merge!(k => v)
    end
  end

  # Category subpages
  def test_category
    get :category

    assert_response 301
  end

  def test_tag
    get :tag, :id => "foo"

    assert_response :success
    assert_template "index"

    assert_tag :tag => 'title', :content => 'test blog : tag foo'
    assert_tag :tag => 'h2', :content => 'Article 2!'
    assert_tag :tag => 'h2', :content => 'Article 1!'
  end

  def test_nonexistent_tag
    get :tag, :id => "nonexistent"
    assert_response 200
    assert_template "error"
  end

  def test_tag_routes
    opts = {:controller => "articles", :action => "tag", :id => "foo", :page => "2"}
    assert_routing("articles/tag/foo/page/2", opts)
  end

  def test_simple_tag_pagination
    this_blog.limit_article_display = 1
    get :tag, :id => "foo"
    assert_equal 1, assigns(:articles).size
    assert_tag(:tag => 'p',
               :attributes =>{ :id => 'pagination' },
               :content => %r{Older posts: 1},
               :descendant => {:tag => 'a',
                               :attributes =>{
                                  :href => "/articles/tag/foo/page/2"},
                               :content => "2"})
  end

  # Main index
  def test_index
    get :index
    assert_response :success
    assert_template "index"
  end

  # Archives page
  def test_archives
    get :archives
    assert_response :success
    assert_template "archives"
  end

  def test_blog_title
    blogs(:default).title_prefix = 1
    get :show, :year => 2004, :month => 06, :day => 01, :id => "article-3"
    assert_response :success
    assert_tag :tag => 'title', :content => /^test blog : Article 3!$/

    blogs(:default).title_prefix = 0
    @controller = ArticlesController.new
    assert_equal 0, blogs(:default).title_prefix
    get :show, :year => 2004, :month => 06, :day => 01, :id => "article-3"
    assert_response :success
    assert_tag :tag => 'title', :content => /^Article 3!$/
  end

  # Permalinks
  def test_show
    get :show, :year => 2004, :month => 06, :day => 01, :id => "article-3"
    assert_response :success
    assert_template "read"
    assert_not_nil assigns(:article)
    assert_equal contents(:article3), assigns(:article)
  end

  # Posts for given day
  def test_find_by_date
    get :index, :year => 2004, :month => 06, :day => 01
    assert_response :success
    assert_template "index"
  end

  def test_comment_posting
    emails = ActionMailer::Base.deliveries
    emails.clear

    assert_equal 0, emails.size

    Article.find(1).notify_users << users(:tobi)

    post_comment(Article.find(1), 'body' => 'This is *markdown*', 'author' => 'bob')

    assert_response :success
    assert_tag :tag => 'em', :content => 'markdown'

    comment = Article.find(1).comments.last
    assert comment

    assert_not_nil cookies["author"]

    assert_equal "<p>This is <em>markdown</em></p>", comment.html.to_s

    assert_equal 2, emails.size
    assert_equal User.find(:all,
                           :conditions => ['(notify_via_email = ?) and (notify_on_comments = ?)', true, true],
                           :order => 'email').collect { |each| each.email },
                 emails.collect { |each| each.to[0] }.sort
  end

  def test_comment_spam_markdown_smarty
    this_blog.comment_text_filter = "markdown smartypants"
    test_comment_spam1
  end

  def comment_template_test(expected_html, source_text,
                            art_id=1, author='bob', email='foo', args={})
    with_options(args) do |merger|
      merger.post_comment(Article.find(art_id),
                          'body' => source_text,
                          'author' => author,
                          'email' => email )
    end

    assert_response :success
    comment = Article.find(art_id).comments.last
    assert comment

    assert_match expected_html, comment.html.to_s
    $do_breakpoints
  end

  def test_comment_spam1
    comment_template_test "<p>Link to <a href=\"http://spammer.example.com\" rel=\"nofollow\">spammy goodness</a></p>", 'Link to <a href="http://spammer.example.com">spammy goodness</a>'
  end

  def test_comment_spam2
    comment_template_test %r{<p>Link to <a href=["']http://spammer.example.com['"] rel=["']nofollow['"]>spammy goodness</a></p>}, 'Link to [spammy goodness](http://spammer.example.com)'
  end

  def test_comment_spam3
    post_comment(Article.find(1),
                 :body => '<a href="http://spam.org">spam</a>',
                 :author => '<a href="spamme.com">spamme</a>',
                 :email => '<a href="http://morespam.net">foo</a>')

    assert_response :success
    comment = Article.find(1).comments.last
    assert comment

    show_article(Article.find(1))
    assert_response 200

    assert ! (@response.body =~ %r{<a href="http://spamme.com">}), "Author leaks"
    assert ! (@response.body =~ %r{<a href="http://spam.org">}), "Body leaks <a>"
    assert ! (@response.body =~ %r{<a href="http://morespam.net">}), "Email leaks"
  end

  def test_comment_xss1
    this_blog.comment_text_filter = "none"
    comment_template_test %{Have you ever alert("foo"); been hacked?},
    %{Have you ever <script lang="javascript">alert("foo");</script> been hacked?}
  end

  def test_comment_xss2
    this_blog.comment_text_filter = "none"
    comment_template_test "Have you ever <a href=\"#\" rel=\"nofollow\">been hacked?</a>", 'Have you ever <a href="#" onclick="javascript">been hacked?</a>'
  end

  def test_comment_autolink
    comment_template_test "<p>What's up with <a href=\"http://slashdot.org\" rel=\"nofollow\">http://slashdot.org</a> these days?</p>", "What's up with http://slashdot.org these days\?"
  end

  ### TODO -- there's a bug in Rails with auto_links
#   def test_comment_autolink2
#     comment_template_test "<p>My web page is <a href='http://somewhere.com/~me/index.html' rel=\"nofollow\">http://somewhere.com/~me/index.html</a></p>", "My web page is http://somewhere.com/~me/index.html"
#   end

  def test_feedback_nuking
    opts = { :article_year => '2007', :article_month => '9', :article_day => '2', :id => 'slug', :feedback_id => feedback(:spam_comment).id }
    feedback_count = Feedback.count
    delete :nuke_feedback, opts, {}
    assert_response 403

    get :nuke_feedback, opts, { :user => users(:bob)}
    assert_response 403

    delete :nuke_feedback, opts, { :user => users(:bob)}
    assert_response :success
    assert_equal feedback_count -1, Feedback.count
  end

  def test_comment_user_blank
    post_comment Article.find(2), 'body' => 'foo', 'author' => 'bob'
    assert_response :success

    comment = Article.find(2).comments.last
    assert comment
    assert comment.published?
    assert_nil comment.user_id

    show_article(Article.find(2))
    assert_response :success
    assert_no_tag :tag => "li",
       :attributes => { :class => "author_comment"}

  end

  def test_comment_user_set
    @request.session = { :user => users(:tobi) }
    post_comment Article.find(2), 'body' => 'foo', 'author' => 'bob'
    assert_response :success

    comment = Article.find(2).comments.last
    assert comment
    assert_equal users(:tobi), comment.user

    show_article(Article.find(2))
    assert_response :success
    assert_tag :tag => "li",
       :attributes => { :class => "author_comment"}
  end

  def test_trackback
    num_trackbacks = Article.find(2).trackbacks.count
    post :trackback, { :id => 2, :url => "http://www.google.com", :title => "My Trackback", :excerpt => "This is a test" }
    assert_response :success
    assert_no_tag :tag => "response",
                  :child => {:tag => "error", :content => "1"}

    assert_equal num_trackbacks+1, Article.find(2).trackbacks.count
  end

  def test_no_settings
    this_blog.update_attribute(:settings, { })

    get :index

    assert_response :redirect,
                    :controller => "admin/general", :action => "redirect"
  end

  def test_no_users_exist
    this_blog.update_attribute(:settings, { })

    User.destroy_all
    assert User.count.zero?

    get :index
    assert_response :redirect, :controller => "accounts", :action => "signup"

  end

  def test_pages_static
    get :view_page, :name => 'page_one'
    assert_response :success
    assert_template "view_page"

    get :view_page, :name => 'page one'
    assert_response 404
  end

  def test_show_non_published
    show_article(Article.find(4))
    assert_response 404
    assert_template "error"
  end

  def test_tags_non_published
    get :tag, :id => 'bar'
    assert_response :success
    assert_equal 1, assigns(:articles).size
    assert ! assigns(:articles).include?(@article4), "Unpublished article displayed"
  end

  def test_gravatar
    assert ! this_blog.use_gravatar
    show_article(Article.find(1))
    assert_response :success
    assert_template "read"
    assert_no_tag :tag => "img",
      :attributes => { :class => "gravatar" }

    # Switch gravatar integration to on
    this_blog.use_gravatar = true
    @controller = ArticlesController.new
    assert this_blog.use_gravatar
    show_article(Article.find(1))
    assert_response :success
    assert_template "read"
    assert_tag :tag => "img",
      :attributes => {
        :class => "gravatar",
        :src => "http://www.gravatar.com/avatar.php?gravatar_id=740618d2fe0450ec244d8b86ac1fe3f8&amp;size=60"
      }
  end

  def test_comment_preview
    get :comment_preview
    assert_response :success
    assert_template nil

    get :comment_preview, :comment => { :author => "bob", :body => "comment preview" }
    assert_response :success
    assert_template "comment_preview"

    assert_tag :tag => "cite",
      :children => { :count => 1,
        :only => { :tag => "strong",
          :content => "bob" } }

    assert_tag :tag => "p",
      :content => "comment preview"
  end

  def test_read_article_with_comments_and_trackbacks
    show_article(contents(:article1))
    assert_response :success
    assert_template "read"

    assert_equal(contents(:article1).comments.to_a.select{|c| c.published?},
                 contents(:article1).published_comments)

    assert_select "ol#commentList" do
      assert_select ">li", contents(:article1).published_comments.size
    end

    assert_select "li.author_comment"

    assert_select "ol#trackbackList > li", contents(:article1).trackbacks.size


#     assert_tag :tag => "ol",
#       :attributes => { :id => "trackbackList" },
#       :children => { :count => contents(:article1).trackbacks.size,
#         :only => { :tag => "li" } }
  end

  def test_show_article_no_comments_no_trackbacks
    show_article(contents(:article3))
    assert_response :success
    assert_template "read"

    assert_tag :tag => "ol",
      :attributes => { :id => "commentList"},
      :children => { :count => 1,
        :only => { :tag => "li",
          :attributes => { :id => "dummy_comment", :style => "display: none" } } }

    assert_no_tag :tag => "ol",
      :attributes => { :id => "trackbackList" }
  end

  def test_autodiscovery_default

    get :index
    assert_response :success
    assert_select 'link[title=RSS]' do
      assert_select '[rel=alternate]'
      assert_select '[type=application/rss+xml]'
      assert_select '[href=http://test.host/articles.rss]'
    end
    assert_select 'link[title=Atom]' do
      assert_select '[rel=alternate]'
      assert_select '[type=application/atom+xml]'
      assert_select '[href=http://test.host/articles.atom]'
    end
  end

  def test_autodiscovery_article
    show_article(Article.find(1))
    assert_response :success

    assert_select 'link[title=RSS]' do
      assert_select '[rel=alternate]'
      assert_select '[type=application/rss+xml]'
      assert_select '[href=?]', formatted_article_url(Article.find(1), 'rss')
    end
    assert_select 'link[title=Atom]' do
      assert_select '[rel=alternate]'
      assert_select '[type=application/atom+xml]'
      assert_select '[href=?]', formatted_article_url(Article.find(1), 'atom')
    end
  end

  def test_autodiscovery_tag
    get :tag, :id => 'hardware'
    assert_response :success
    assert_select 'link[title=RSS]' do
      assert_select '[rel=alternate]'
      assert_select '[type=application/rss+xml]'
      assert_select '[href=http://test.host/articles/tag/hardware.rss]'
    end
    assert_select 'link[title=Atom]' do
      assert_select '[rel=alternate]'
      assert_select '[type=application/atom+xml]'
      assert_select '[href=http://test.host/articles/tag/hardware.atom]'
    end
  end

  def test_disabled_ajax_comments
    this_blog.sp_allow_non_ajax_comments = false
    assert_equal false, this_blog.sp_allow_non_ajax_comments

    post_comment Article.find(1), 'body' => 'This is posted without ajax', 'author' => 'bob'
    assert_response 500
    assert_equal "non-ajax commenting is disabled", @response.body

    @request.env['HTTP_X_REQUESTED_WITH'] = "XMLHttpRequest"
    post_comment Article.find(1), 'body' => 'This is posted *with* ajax', 'author' => 'bob'
    assert_response :success
    ajax_comment = Article.find(1).comments.last
    assert_equal "This is posted *with* ajax", ajax_comment.body
  end

  def test_tag_max_article_count_is_first
    tags = Tag.find_all_with_article_counters
    assert tags.size > 1
    max = tags[0].article_counter
    tags.each do |tag|
      assert tag.article_counter <= max
    end
  end


  def test_hide_future_article
    @article = Article.find_last_posted

    Article.create!(:title      => "News from the future!",
                    :body       => "The future is cool!",
                    :keywords   => "future",
                    :published  => true,
                    :published_at => Time.now + 12.minutes)
    get :index
    assert_equal @article, assigns(:articles).first
    assert @response.lifetime.to_i <= 12.minutes
  end

  def test_search
    get :search, :q => "search target"
    assert_equal 1, assigns(:articles).size
  end

  def test_author
    get :author, :id => 'tobi'

    assert_response :success
    assert_template 'index'
    assert assigns(:articles)
    assert_equal users(:tobi).articles.published, assigns(:articles)
    # This is until we write a proper author feed

    assert_equal('http://test.host/articles/author/tobi.rss',
                 assigns(:auto_discovery_url_rss))
    assert_equal('http://test.host/articles/author/tobi.atom',
                 assigns(:auto_discovery_url_atom))
  end

  def test_nonexistent_author
    get :author, :id => 'nonexistent-chap'

    assert_response 404
    assert_template 'error'
    assert assigns(:message)
    assert_equal "Can't find posts with author 'nonexistent-chap'", assigns(:message)
  end

  def test_author_list
    get :author

    assert_response :success
    assert_template 'groupings'

    assert_tag(:tag => 'ul',
               :descendant => {\
                 :tag => 'a',
                 :attributes => { :href => '/articles/author/tobi' },
               })
  end
end
