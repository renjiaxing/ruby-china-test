# coding: utf-8
require "auto-space"
class Topic
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::BaseModel
  include Mongoid::SoftDelete
  include Mongoid::CounterCache
  include Mongoid::Likeable
  include Mongoid::MarkdownBody
  include Redis::Objects
  include Mongoid::Mentionable

  field :title
  field :body
  field :body_html
  field :last_reply_id, type: Integer
  field :replied_at, type: DateTime
  field :source
  field :message_id
  field :replies_count, type: Integer, default: 0
  # 回复过的人的 ids 列表
  field :follower_ids, type: Array, default: []
  field :suggested_at, type: DateTime
  # 最后回复人的用户名 - cache 字段用于减少列表也的查询
  field :last_reply_user_login
  # 节点名称 - cache 字段用于减少列表也的查询
  field :node_name
  # 删除人
  field :who_deleted
  # 用于排序的标记
  field :last_active_mark, type: Integer
  # 是否锁定节点
  field :lock_node, type: Mongoid::Boolean, default: false
  # 精华帖 0 否， 1 是
  field :excellent, type: Integer, default: 0

  # 临时存储检测用户是否读过的结果
  attr_accessor :read_state

  belongs_to :user, inverse_of: :topics
  counter_cache name: :user, inverse_of: :topics
  belongs_to :node
  counter_cache name: :node, inverse_of: :topics
  belongs_to :last_reply_user, class_name: 'User'
  belongs_to :last_reply, class_name: 'Reply'
  has_many :replies, dependent: :destroy

  validates_presence_of :user_id, :title, :body, :node

  index node_id: 1
  index user_id: 1
  index last_active_mark: -1
  index likes_count: 1
  index suggested_at: 1
  index excellent: -1

  counter :hits, default: 0

  delegate :login, to: :user, prefix: true, allow_nil: true
  delegate :body, to: :last_reply, prefix: true, allow_nil: true

  # scopes
  scope :last_actived, -> { desc(:last_active_mark) }
  # 推荐的话题
  scope :suggest, -> { where(:suggested_at.ne => nil).desc(:suggested_at) }
  scope :fields_for_list, -> { without(:body, :body_html) }
  scope :high_likes, -> { desc(:likes_count, :_id) }
  scope :high_replies, -> { desc(:replies_count, :_id) }
  scope :no_reply, -> { where(replies_count: 0) }
  scope :popular, -> { where(:likes_count.gt => 5) }
  scope :without_node_ids, Proc.new { |ids| where(:node_id.nin => ids) }
  scope :excellent, -> { where(:excellent.gte => 1) }

  def self.find_by_message_id(message_id)
    where(message_id: message_id).first
  end

  # 排除隐藏的节点
  def self.without_hide_nodes
    where(:node_id.nin => self.topic_index_hide_node_ids)
  end

  def self.topic_index_hide_node_ids
    SiteConfig.node_ids_hide_in_topics_index.to_s.split(",").collect { |id| id.to_i }
  end

  before_save :store_cache_fields

  def store_cache_fields
    self.node_name = self.node.try(:name) || ""
  end

  before_save :auto_space_with_title

  def auto_space_with_title
    self.title.auto_space!
  end

  before_create :init_last_active_mark_on_create

  def init_last_active_mark_on_create
    self.last_active_mark = Time.now.to_i
  end

  def push_follower(uid)
    return false if uid == self.user_id
    return false if self.follower_ids.include?(uid)
    self.push(follower_ids: uid)
    true
  end

  def pull_follower(uid)
    return false if uid == self.user_id
    self.pull(follower_ids: uid)
    true
  end

  def update_last_reply(reply, opts = {})
    # replied_at 用于最新回复的排序，如果帖着创建时间在一个月以前，就不再往前面顶了
    return false if reply.blank? && !opts[:force]

    self.last_active_mark = Time.now.to_i if self.created_at > 1.month.ago
    self.replied_at = reply.try(:created_at)
    self.last_reply_id = reply.try(:id)
    self.last_reply_user_id = reply.try(:user_id)
    self.last_reply_user_login = reply.try(:user_login)
    self.save
  end

  # 更新最后更新人，当最后个回帖删除的时候
  def update_deleted_last_reply(deleted_reply)
    return false if deleted_reply.blank?
    return false if self.last_reply_user_id != deleted_reply.user_id

    previous_reply = self.replies.where(:_id.nin => [deleted_reply.id]).recent.first
    self.update_last_reply(previous_reply, force: true)
  end

  # 删除并记录删除人
  def destroy_by(user)
    return false if user.blank?
    self.update_attribute(:who_deleted, user.login)
    self.destroy
  end

  def destroy
    super
    delete_notifiaction_mentions
  end

  def last_page_with_per_page(per_page)
    page = (self.replies_count.to_f / per_page).ceil
    page > 1 ? page : nil
  end

  # 所有的回复编号
  def reply_ids
    Rails.cache.fetch([self, "reply_ids"]) do
      self.replies.only(:_id).map(&:_id)
    end
  end

  def excellent?
    self.excellent >= 1
  end

  #以小时为单位计算回复数量
  def Reply.reply_hours_stat(from_time, to_time)
    map = %Q{
    function() {
      emit(this.topic_id, {count: 1})
    }
  }

    reduce = %Q{
    function(key, values) {
      var result = {count: 0};
      values.forEach(function(value) {
        result.count += value.count;
      });
      return result;
    }
  }

    Reply.where(:created_at.gte => Time.now-from_time.hours, :created_at.lt => Time.now-to_time.hours).map_reduce(map, reduce).out(inline: true)
  end

  #以小时为单位计算浏览数量
  def Impression.access_hours_stat(from_time, to_time)
    map = %Q{
    function() {
      emit(this.impressionable_id, {count: 1})
    }
  }

    reduce = %Q{
    function(key, values) {
      var result = {count: 0};
      values.forEach(function(value) {
        result.count += value.count;
      });
      return result;
    }
  }

    Impression.where(:created_at.gte => Time.now-from_time.hours, :created_at.lt => Time.now-to_time.hours).map_reduce(map, reduce).out(inline: true)
  end

  #以小时为单位计算vi+3pi的值 没有进行加权
  def self.topic_hour_score(from_time, to_time)
    all_ids=[]
    result={}

    reply_temp={}
    impress_temp={}

    #产生的结果都是hash值的
    Reply.reply_hours_stat(from_time, to_time).each { |p| reply_temp[p["_id"].to_i]=p["value"]["count"] }
    Impression.access_hours_stat(from_time, to_time).each { |p| impress_temp[p["_id"].to_i]=p["value"]["count"] }

    #计算合集
    all_ids=reply_temp.keys|impress_temp.keys

    all_ids.each do |t|
      result[t]=((impress_temp[t].nil?) ? 0 : impress_temp[t])+3*((reply_temp[t].nil?) ? 0 : reply_temp[t])
    end

    return result
  end

  #计算加权后的结果 然后返回排序的topic数组
  def self.hot_hour_topics(t)
    result={}
    topics=[]
    for i in 1..t
      result_temp=topic_hour_score(i, i-1)
      result_temp.keys.each do |r|
        if result[r].nil?
          result[r]=result_temp[r]*(25-i)
        else
          result[r]+=result_temp[r]*(25-i)
        end
      end
    end
    #进行排序
    result_tmp=result.sort { |a, b| a[1]<=>b[1] }.reverse
    #选择前100项
    if result_tmp.size>100
      result_tmp[0..99].each do |t|
        topics.push(Topic.find(t[0]))
      end
    else
      result_tmp.each do |t|
        topics.push(Topic.find(t[0]))
      end
    end
    return topics
  end

  #以天为单位计算回复数量
  def Reply.reply_days_stat(from_time, to_time)
    map = %Q{
    function() {
      emit(this.topic_id, {count: 1})
    }
  }

    reduce = %Q{
    function(key, values) {
      var result = {count: 0};
      values.forEach(function(value) {
        result.count += value.count;
      });
      return result;
    }
  }

    Reply.where(:created_at.gte => Time.now-from_time.days, :created_at.lt => Time.now-to_time.days).map_reduce(map, reduce).out(inline: true)
  end

  #以天为单位计算浏览数量
  def Impression.access_days_stat(from_time, to_time)
    map = %Q{
    function() {
      emit(this.impressionable_id, {count: 1})
    }
  }

    reduce = %Q{
    function(key, values) {
      var result = {count: 0};
      values.forEach(function(value) {
        result.count += value.count;
      });
      return result;
    }
  }

    Impression.where(:created_at.gte => Time.now-from_time.days, :created_at.lt => Time.now-to_time.days).map_reduce(map, reduce).out(inline: true)
  end

  #以天为单位计算vi+3*pi 没有进行加权
  def self.topic_day_score(from_time, to_time)
    all_ids=[]
    result={}

    reply_temp={}
    impress_temp={}
    Reply.reply_days_stat(from_time, to_time).each { |p| reply_temp[p["_id"].to_i]=p["value"]["count"] }
    Impression.access_days_stat(from_time, to_time).each { |p| impress_temp[p["_id"].to_i]=p["value"]["count"] }

    all_ids=reply_temp.keys|impress_temp.keys

    all_ids.each do |t|
      result[t]=((impress_temp[t].nil?) ? 0 : impress_temp[t])+3*((reply_temp[t].nil?) ? 0 : reply_temp[t])
    end

    return result
  end

  #计算t天以内的加权结果 返回topic的数组
  def self.hot_day_topics(t)
    result={}
    topics=[]
    for i in 1..t
      result_temp=topic_day_score(i, i-1)
      result_temp.keys.each do |r|
        if result[r].nil?
          result[r]=result_temp[r]*(25-i)
        else
          result[r]+=result_temp[r]*(25-i)
        end
      end
    end
    result_tmp=result.sort { |a, b| a[1]<=>b[1] }.reverse
    if result_tmp.size>100
      result_tmp[0..99].each do |t|
        topics.push(Topic.find(t[0]))
      end
    else
      result_tmp.each do |t|
        topics.push(Topic.find(t[0]))
      end
    end
    return topics
  end


end
