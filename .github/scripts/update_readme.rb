# frozen_string_literal: true

require "net/http"
require "uri"
require "rexml/document"
require "json"
require "time"

README_PATH = File.expand_path("../../profile/README.md", __dir__)
BLOG_FEED_URL = "https://builtfast.dev/feed.xml"
CHANGELOG_FEED_URL = "https://builtfast.dev/changelog/feed.xml"
GITHUB_ORG = "built-fast"

def fetch_url(url)
  uri = URI(url)
  response = Net::HTTP.get_response(uri)

  if response.is_a?(Net::HTTPRedirection)
    fetch_url(response["location"])
  elsif response.is_a?(Net::HTTPSuccess)
    response.body
  end
rescue StandardError => e
  warn "Failed to fetch #{url}: #{e.message}"
  nil
end

def fetch_atom_feed(url)
  body = fetch_url(url)
  return nil unless body

  REXML::Document.new(body)
rescue StandardError => e
  warn "Failed to parse feed from #{url}: #{e.message}"
  nil
end

def latest_blog_posts(doc, count = 4)
  return [] unless doc

  posts = []
  REXML::XPath.each(doc, "//entry") do |entry|
    break if posts.length >= count

    title = entry.elements["title"]&.text
    link = entry.elements["link"]&.attributes&.[]("href")
    published = entry.elements["published"]&.text || entry.elements["updated"]&.text
    next unless title && link

    date = Time.parse(published).strftime("%b %-d, %Y") if published
    posts << {title: title, url: link, date: date}
  end

  posts
end

def latest_changelog_entries(doc, count = 3)
  return [] unless doc

  entries = []
  REXML::XPath.each(doc, "//entry") do |entry|
    break if entries.length >= count

    title = entry.elements["title"]&.text
    link = entry.elements["link"]&.attributes&.[]("href")
    updated = entry.elements["updated"]&.text
    next unless title && link

    date = if updated
      Time.parse(updated).strftime("%b %-d, %Y")
    end

    entries << {title: title, url: link, date: date}
  end

  entries
end

def fetch_github_stats(org)
  token = ENV["GH_TOKEN"]
  headers = {"Accept" => "application/vnd.github+json", "User-Agent" => "bf-readme-updater"}
  headers["Authorization"] = "Bearer #{token}" if token

  repos = []
  page = 1

  loop do
    uri = URI("https://api.github.com/orgs/#{org}/repos?type=public&per_page=100&page=#{page}")
    req = Net::HTTP::Get.new(uri, headers)
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
    break unless res.is_a?(Net::HTTPSuccess)

    batch = JSON.parse(res.body)
    break if batch.empty?

    repos.concat(batch)
    page += 1
  end

  stars = repos.sum { |r| r["stargazers_count"] || 0 }

  members_uri = URI("https://api.github.com/orgs/#{org}/public_members?per_page=100")
  members_req = Net::HTTP::Get.new(members_uri, headers)
  members_res = Net::HTTP.start(members_uri.hostname, members_uri.port, use_ssl: true) { |http| http.request(members_req) }
  contributors = if members_res.is_a?(Net::HTTPSuccess)
    JSON.parse(members_res.body).length
  else
    0
  end

  {repos: repos.length, stars: stars, contributors: contributors}
rescue StandardError => e
  warn "Failed to fetch GitHub stats: #{e.message}"
  nil
end

def render_badges(stats)
  return nil unless stats

  repos_badge = "![Public Repos](https://img.shields.io/badge/repos-#{stats[:repos]}-blue)"
  stars_badge = "![Total Stars](https://img.shields.io/badge/stars-#{stats[:stars]}-yellow)"
  contributors_badge = "![Contributors](https://img.shields.io/badge/contributors-#{stats[:contributors]}-green)"

  "#{repos_badge} #{stars_badge} #{contributors_badge}"
end

def render_recently_shipped(entries)
  return nil if entries.empty?

  entries.map { |e|
    line = "- [#{e[:title]}](#{e[:url]})"
    line += " — #{e[:date]}" if e[:date]
    line
  }.join("\n")
end

def render_blog_posts(posts)
  return nil if posts.empty?

  lines = ["**Latest from the blog:**", ""]
  posts.each do |p|
    line = "- [#{p[:title]}](#{p[:url]})"
    line += " — #{p[:date]}" if p[:date]
    lines << line
  end

  lines.join("\n")
end

def update_readme(path, sections)
  content = File.read(path)

  sections.each do |name, body|
    next unless body

    marker_re = /<!-- START:#{Regexp.escape(name)} -->\n(?:.*\n)*?<!-- END:#{Regexp.escape(name)} -->/
    replacement = "<!-- START:#{name} -->\n#{body}\n<!-- END:#{name} -->"

    if content.match?(marker_re)
      content.gsub!(marker_re, replacement)
    else
      warn "Marker <!-- START:#{name} --> not found in README, skipping"
    end
  end

  File.write(path, content)
end

# --- Main ---

puts "Fetching blog feed..."
blog_doc = fetch_atom_feed(BLOG_FEED_URL)
blog_posts = latest_blog_posts(blog_doc, 4)

puts "Fetching changelog feed..."
changelog_doc = fetch_atom_feed(CHANGELOG_FEED_URL)
changelog_entries = latest_changelog_entries(changelog_doc, 3)

puts "Fetching GitHub stats..."
stats = fetch_github_stats(GITHUB_ORG)

sections = {
  "blog_post" => render_blog_posts(blog_posts),
  "badges" => render_badges(stats),
  "recently_shipped" => render_recently_shipped(changelog_entries)
}

puts "Updating README..."
update_readme(README_PATH, sections)

sections.each do |name, body|
  if body
    puts "  #{name}: updated"
  else
    puts "  #{name}: skipped (no data)"
  end
end

puts "Done."
