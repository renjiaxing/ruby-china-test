class JobsController < ApplicationController
  helper_method :feed_node_topics_url
  
  def feed_node_topics_url
    # super.feed_node_topics_url(id: 25)
  end
  
  def index
    @node = Node.find(25)
    @topics = @node.topics.last_actived.fields_for_list.includes(:user).paginate(:page => params[:page],:per_page => 15)
    set_seo_meta("#{@node.name} &raquo; #{t("menu.topics")}","#{Setting.app_name}#{t("menu.topics")}#{@node.name}",@node.summary)
    drop_breadcrumb("#{@node.name}")
    render "/topics/index"
  end
end