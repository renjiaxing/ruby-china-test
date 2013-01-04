# coding: utf-8
require 'rails'
require 'rails_autolink'
require 'redcarpet'
require 'singleton'
require 'md_emoji'
require 'pygments'

module Redcarpet
  module Render
    class HTMLwithSyntaxHighlight < HTML

      def initialize(extensions={})
        super(extensions.merge(:xhtml => true,
                               :no_styles => true,
                               :filter_html => true,
                               :hard_wrap => true))
      end

      def block_code(code, language)
        language = 'text' if language.blank?
        begin
          Pygments.highlight(code, :lexer => language, :formatter => 'html', :options => {:encoding => 'utf-8'})
        rescue
          Pygments.highlight(code, :lexer => 'text', :formatter => 'html', :options => {:encoding => 'utf-8'})
        end
      end

      def autolink(link, link_type)
        # return link
        if link_type.to_s == "email"
          link
        else
          begin
            # 防止 C 的 autolink 出来的内容有编码错误，万一有就直接跳过转换
            # 比如这句:
            # 此版本并非线上的http://yavaeye.com的源码.
            link.match(/.+?/)
          rescue
            return link
          end
          # Fix Chinese neer the URL
          bad_text = link.to_s.match(/[^\w:\/\-\,\$\!\.=\?&#+\|\%]+/im).to_s
          link = link.to_s.gsub(bad_text, '')
          "<a href=\"#{link}\" rel=\"nofollow\" target=\"_blank\">#{link}</a>#{bad_text}"
        end
      end
    end

    class HTMLwithTopic < HTMLwithSyntaxHighlight
      # Topic 里面，所有的 head 改为 h4 显示
      def header(text, header_level)
        "<h4>#{text}</h4>"
      end
    end
  end
end

class MarkdownConverter
  include Singleton

  def self.convert(text)
    self.instance.convert(text)
  end

  def convert(text)
    @converter.render(text)
  end

  private
  def initialize
    @converter = Redcarpet::Markdown.new(Redcarpet::Render::HTMLwithSyntaxHighlight.new, {
        :autolink => true,
        :fenced_code_blocks => true,
        :no_intra_emphasis => true
      })
  end
end

class MarkdownTopicConverter < MarkdownConverter
  def self.format(raw)
    self.instance.format(raw)
  end

  def format(raw)
    text = raw.clone
    return '' if text.blank?

    convert_bbcode_img(text)
    users = nomalize_user_mentions(text)

    # 如果 ``` 在刚刚换行的时候 Redcapter 无法生成正确，需要两个换行
    text.gsub!("\n```","\n\n```")

    result = convert(text)

    doc = Nokogiri::HTML.fragment(result, 'UTF-8')
    link_mention_floor(doc)
    link_mention_user(doc, users)
    replace_emoji(doc)

    return doc.to_html(:encoding => 'UTF-8').strip
  rescue => e
    puts "MarkdownTopicConverter.format ERROR: #{e}"
    return text
  end

  private
  # convert bbcode-style image tag [img]url[/img] to markdown syntax ![alt](url)
  def convert_bbcode_img(text)
    text.gsub!(/\[img\](.+?)\[\/img\]/i) {"![#{image_alt $1}](#{$1})"}
  end

  def image_alt(src)
    File.basename(src, '.*').capitalize
  end

  # borrow from html-pipeline
  def has_ancestors?(node, tags)
    while node = node.parent
      if tags.include?(node.name.downcase)
        break true
      end
    end
  end

  # convert '#N楼' to link
  # Refer to emoji_filter in html-pipeline
  def link_mention_floor(doc)
    doc.search('text()').each do |node|
      content = node.to_html(:encoding => 'UTF-8')
      next if !content.include?('#')
      next if has_ancestors?(node, %w(pre code))

      html = content.gsub(/#(\d+)([楼樓Ff])/) {
        %(<a href="#reply#{$1}" class="at_floor" data-floor="#{$1}">##{$1}#{$2}</a>)
      }

      next if html == content
      node.replace(html)
    end
  end

  NOMALIZE_USER_REGEXP = /(^|[^a-zA-Z0-9_!#\$%&*@＠])@([a-zA-Z0-9_]{1,20})/io
  LINK_USER_REGEXP = /(^|[^a-zA-Z0-9_!#\$%&*@＠])@(user[0-9]{1,6})/io

  # rename user name using incremental id
  def nomalize_user_mentions(text)
    users = []

    text.gsub!(NOMALIZE_USER_REGEXP) do
      prefix = $1
      user = $2
      users.push(user)
      "#{prefix}@user#{users.size}"
    end

    users
  end

  # convert '@user' to link
  # match any user even not exist.
  def link_mention_user(doc, users)
    doc.search('text()').each do |node|
      content = node.to_html(:encoding => 'UTF-8')
      next if !content.include?('@')
      in_code = has_ancestors?(node, %w(pre code))
      html = content.gsub(LINK_USER_REGEXP) {
        prefix = $1
        user_placeholder = $2
        user_id = user_placeholder.sub(/^user/, '').to_i
        user = users[user_id - 1] || user_placeholder

        if in_code
          "#{prefix}@#{user}"
        else
          %(#{prefix}<a href="/#{user}" class="at_user" title="@#{user}"><i>@</i>#{user}</a>)
        end
      }

      node.replace(html)
    end
  end

  def replace_emoji(doc)
    doc.search('text()').each do |node|
      content = node.to_html(:encoding => 'UTF-8')
      next if !content.include?(':')
      next if has_ancestors?(node, %w(pre code))

      html = content.gsub(/:(\S+):/) do |emoji|

        emoji_code = emoji #.gsub("|", "_")
        emoji      = emoji_code.gsub(":", "")

        if MdEmoji::EMOJI.include?(emoji)
          file_name    = "#{emoji.gsub('+', 'plus')}.png"

          %{<img src="#{upload_url}/assets/emojis/#{file_name}" class="emoji" } +
            %{title="#{emoji_code}" alt="" />}
        else
          emoji_code
        end
      end

      next if html == content
      node.replace(html)
    end
  end

  def upload_url
    Setting.upload_url
  end

  def initialize
    @converter = Redcarpet::Markdown.new(Redcarpet::Render::HTMLwithTopic.new, {
        :autolink => true,
        :fenced_code_blocks => true,
        :strikethrough => true,
        :space_after_headers => true,
        :no_intra_emphasis => true
      })
    # @emoji = Redcarpet::Markdown.new(MdEmoji::Render)
    @emoji = MdEmoji::Render.new
  end
end
