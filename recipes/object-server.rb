#
# Cookbook Name:: swift
# Recipe:: swift-object-server
#
# Copyright 2012, Rackspace Hosting
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

include_recipe "swift::common"
include_recipe "swift::drive-audit"
include_recipe "swift::disks"

package "swift-object" do
  action :upgrade
  options "-o Dpkg::Options:='--force-confold' -o Dpkg::Options:='--force-confdef'"
end

service "swift-object" do
  supports :status => true, :restart => true
  action :enable
  only_if "[ -e /etc/swift/object-server.conf ] && [ -e /etc/swift/object.ring.gz ]"
end

template "/etc/swift/object-server.conf" do
  source "object-server.conf.erb"
  owner "swift"
  group "swift"
  mode "0600"
  notifies :restart, resources(:service => "swift-object"), :immediately
end

