#
# Cookbook Name:: swift
# Recipe:: ring-repo
#
# Copyright 2012, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# This recipe creates a git ring repository on the management node
# for purposes of ring synchronization
#

if not node['package_component'].nil?
    release = node['package_component']
else
    release = "essex-final"
end

case node['platform']
when "redhat", "centos", "fedora"
  platform_options = node["swift"]["platform"]
when "ubuntu"
  platform_options = node["swift"]["platform"][release]
end

platform_options["git_packages"].each do |pkg|
  package pkg do
    action :upgrade
  end
end

service "xinetd" do
  supports :status => false, :restart => true
  action [ :enable, :start ]
  only_if { platform?(%w{centos redhat fedora}) }
end

execute "create empty git repo" do
  cwd "/tmp"
  umask 022
  command "mkdir $$; cd $$; git init; echo \"backups\" \> .gitignore; git add .gitignore; git commit -m 'initial commit' --author='chef <chef@openstack>'; git push file:///#{platform_options["git_dir"]}/rings master"
  user "swift"
  action :nothing
end

directory "git-directory" do
  path "#{platform_options["git_dir"]}/rings"
  owner "swift"
  group "swift"
  mode "0755"
  recursive true
  action :create
end

execute "initialize git repo" do
  cwd "#{platform_options["git_dir"]}/rings"
  umask 022
  user "swift"
  command "git init --bare && touch git-daemon-export-ok"
  creates "#{platform_options["git_dir"]}/rings/config"
  action :run
  notifies :run, resources(:execute => "create empty git repo"), :immediately
end

# epel/f-17 missing systemd-ified inits
# https://bugzilla.redhat.com/show_bug.cgi?id=737183
template "/etc/systemd/system/git.service" do
  owner "root"
  group "root"
  mode "0644"
  source "simple-systemd-config.erb"
  variables({ :description => "Git daemon service",
              :user => "nobody",
              :exec => "/usr/libexec/git-core/git-daemon " +
              "--base-path=/var/lib/git --export-all --user-path=public_git" +
              "--syslog --verbose"
            })
  only_if { platform?(%w{fedora}) }
end

case node["platform"]
when "centos","redhat","fedora"
  service "git-daemon" do
    service_name platform_options["git_service"]
    action [ :enable ]
  end
when "ubuntu","debian"
  service "git-daemon" do
    service_name platform_options["git_service"]
    action [ :enable, :start ]
  end
end

cookbook_file "/etc/default/git-daemon" do
  owner "root"
  group "root"
  mode "644"
  source "git-daemon.default"
  action :create
  notifies :restart, resources(:service => "git-daemon"), :immediately
  not_if { platform?(%w{fedora centos redhat}) }
end

directory "/etc/swift/ring-workspace" do
  owner "swift"
  group "swift"
  mode "0755"
  action :create
end

execute "checkout-rings" do
  cwd "/etc/swift/ring-workspace"
  command "git clone file://#{platform_options["git_dir"]}/rings"
  user "swift"
  creates "/etc/swift/ring-workspace/rings"
end

# FIXME: node attribute - partition power
[ "account", "container", "object" ].each do |ring_type|
  execute "add #{ring_type}.builder" do
    cwd "/etc/swift/ring-workspace/rings"
    command "git add #{ring_type}.builder && git commit -m 'initial ring builders' --author='chef <chef@openstack>'"
    user "swift"
    action :nothing
  end

  execute "create #{ring_type} builder" do
    cwd "/etc/swift/ring-workspace/rings"
    command "swift-ring-builder #{ring_type}.builder create 18 3 1"
    user "swift"
    creates "/etc/swift/ring-workspace/rings/#{ring_type}.builder"
    notifies :run, "execute[add #{ring_type}.builder]", :immediate
  end
end

dsh_group "swift-storage" do
  action :nothing
  execute "sudo /etc/swift/pull-rings.sh"
end

bash "rebuild-rings" do
  action :nothing
  cwd "/etc/swift/ring-workspace/rings"
  user "swift"
  code <<-EOF
    set -e
    set -x

    # Should this be done?
    git reset --hard
    git clean -df

    ../generate-rings.sh
    for d in object account container; do swift-ring-builder ${d}.builder; done

    git add *builder *gz
    git commit -m "Autobuild of rings on $(date +%Y%m%d) by Chef" --author="chef <chef@openstack>"

    # should dsh a ring pull at this point
    git push
  EOF
  notifies :execute, "dsh_group[swift-storage]", :immediate
  only_if { node["swift"]["auto_rebuild_rings"] }
end

swift_ring_script "/etc/swift/ring-workspace/generate-rings.sh" do
  owner "swift"
  group "swift"
  mode "0700"
  ring_path "/etc/swift/ring-workspace/rings"
  action :ensure_exists
  notifies :run, "bash[rebuild-rings]", :immediate
end

