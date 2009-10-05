
--- Functions for managing the repository on disk.
module("luarocks.rep", package.seeall)

local fs = require("luarocks.fs")
local path = require("luarocks.path")
local cfg = require("luarocks.cfg")
local util = require("luarocks.util")
local dir = require("luarocks.dir")
local manif = require("luarocks.manif")
local deps = require("luarocks.deps")

--- Get all installed versions of a package.
-- @param name string: a package name.
-- @return table or nil: An array of strings listing installed
-- versions of a package, or nil if none is available.
function get_versions(name)
   assert(type(name) == "string")
   
   local dirs = fs.list_dir(path.versions_dir(name))
   return (dirs and #dirs > 0) and dirs or nil
end

--- Check if a package exists in a local repository.
-- Version numbers are compared as exact string comparison.
-- @param name string: name of package
-- @param version string: package version in string format
-- @return boolean: true if a package is installed,
-- false otherwise.
function is_installed(name, version)
   assert(type(name) == "string")
   assert(type(version) == "string")
      
   return fs.is_dir(path.install_dir(name, version))
end

--[[
--- Install bin entries in the repository bin dir.
-- @param name string: name of package
-- @param version string: package version in string format
-- @param single_file string or nil: optional parameter, indicating the name
-- of a single file to install; if not given, all bin files from the package
-- are installed.
-- @return boolean or (nil, string): True if succeeded or nil and
-- and error message.
function install_bins(name, version, single_file)
   assert(type(name) == "string")
   assert(type(version) == "string")

   local bindir = path.bin_dir(name, version)
   if fs.exists(bindir) then
      local ok, err = fs.make_dir(cfg.deploy_bin_dir)
      if not ok then
         return nil, "Could not create "..cfg.deploy_bin_dir
      end
      local files = single_file and {single_file} or fs.list_dir(bindir)
      for _, file in pairs(files) do
         local fullname = dir.path(bindir, file)
         local match = file:match("%.lua$")
         local file
         if not match then
            file = io.open(fullname)
         end
         if match or (file and file:read():match("#!.*lua.*")) then
            ok, err = fs.wrap_script(fullname, cfg.deploy_bin_dir)
         else
            ok, err = fs.copy_binary(fullname, cfg.deploy_bin_dir)
         end
         if file then file:close() end
         if not ok then
            return nil, err
         end
      end
   end
   return true
end
]]

local function store_package_data(result, name, sub, prefix)
   assert(type(result) == "table")
   assert(type(name) == "string")
   assert(type(sub) == "table" or type(sub) == "string")
   assert(type(prefix) == "string")

   if type(sub) == "table" then
      for sname, ssub in pairs(sub) do
         store_package_data(result, sname, ssub, prefix..name.."/")
      end
   elseif type(sub) == "string" then
      local pathname = prefix..name
      result[path.path_to_module(pathname)] = pathname
   end
end

--- Obtain a list of modules within an installed package.
-- @param package string: The package name; for example "luasocket"
-- @param version string: The exact version number including revision;
-- for example "2.0.1-1".
-- @return table: A table of modules where keys are module identifiers
-- in "foo.bar" format and values are pathnames in architecture-dependent
-- "foo/bar.so" format. If no modules are found or if package or version
-- are invalid, an empty table is returned.
function package_modules(package, version)
   assert(type(package) == "string")
   assert(type(version) == "string")

   local result = {}
   local rock_manifest = manif.load_rock_manifest(package, version)

   if rock_manifest.lib then
      for name,sub in pairs(rock_manifest.lib) do
         store_package_data(result, name, sub, "", "")
      end
   end
   if rock_manifest.lua then
      for name,sub in pairs(rock_manifest.lua) do
         store_package_data(result, name, sub, "", "")
      end
   end
   return result
end

--- Obtain a list of command-line scripts within an installed package.
-- @param package string: The package name; for example "luasocket"
-- @param version string: The exact version number including revision;
-- for example "2.0.1-1".
-- @return table: A table of items where keys are command names
-- as strings and values are pathnames in architecture-dependent
-- ".../bin/foo" format. If no modules are found or if package or version
-- are invalid, an empty table is returned.
function package_commands(package, version)
   assert(type(package) == "string")
   assert(type(version) == "string")

   local result = {}
   local rock_manifest = manif.load_rock_manifest(package, version)
   if rock_manifest.bin then
      for name,sub in pairs(rock_manifest.bin) do
         store_package_data(result, name, sub, "", "")
      end
   end
   return result
end


--- Check if a rock contains binary executables.
-- @param name string: name of an installed rock
-- @param version string: version of an installed rock
-- @return boolean: returns true if rock contains platform-specific
-- binary executables, or false if it is a pure-Lua rock.
function has_binaries(name, version)
   assert(type(name) == "string")
   assert(type(version) == "string")

   local rock_manifest = manif.load_rock_manifest(name, version)
   if rock_manifest.bin then
      for name, md5 in pairs(rock_manifest.bin) do
         -- TODO verify that it is the same file. If it isn't, find the actual command.
         if fs.is_actual_binary(dir.path(cfg.deploy_bin_dir, name)) then
            return true
         end
      end
   end
   return false
end

function run_hook(rockspec, hook_name)
   assert(type(rockspec) == "table")
   assert(type(hook_name) == "string")

   local hooks = rockspec.hooks
   if not hooks then
      return true
   end
   if not hooks.substituted_variables then
      util.variable_substitutions(hooks, rockspec.variables)
      hooks.substituted_variables = true
   end
   local hook = hooks[hook_name]
   if hook then
      print(hook)
      if not fs.execute(hook) then
         return nil, "Failed running "..hook_name.." hook."
      end
   end
   return true
end

local function install_binary(source, target)
   assert(type(source) == "string")
   assert(type(target) == "string")

   local match = source:match("%.lua$")
   local file, ok, err
   if not match then
      file = io.open(source)
   end
   if match or (file and file:read():match("^#!.*lua.*")) then
      ok, err = fs.wrap_script(source, target)
   else
      ok, err = fs.copy_binary(source, target)
   end
   if file then file:close() end
   return ok, err
end

local function resolve_conflict(name, version, target)
   local cname, cversion = manif.find_current_provider(target)
   if not cname then
      return nil, cversion
   end
   if name ~= cname or deps.compare_versions(version, cversion) then
      fs.move(target, path.versioned_name(target, cname, cversion))
      return target
   else
      return path.versioned_name(target, name, version)
   end
end

function deploy_files(name, version)
   assert(type(name) == "string")
   assert(type(version) == "string")

   local function deploy_file_tree(file_tree, source_dir, deploy_dir, move_fn)
      assert(type(file_tree) == "table")
      assert(type(source_dir) == "string")
      assert(type(deploy_dir) == "string")
      assert(type(move_fn) == "function" or not move_fn)
      
      if not move_fn then move_fn = fs.move end
   
      local ok, err = fs.make_dir(deploy_dir)
      if not ok then
         return nil, "Could not create "..deploy_dir
      end
      for file, sub in pairs(file_tree) do
         local source = dir.path(source_dir, file)
         local target = dir.path(deploy_dir, file)
         if type(sub) == "table" then
            ok, err = deploy_file_tree(sub, source, target)
            if not ok then return nil, err end
            fs.remove_dir_if_empty(source)
         else
            if fs.exists(target) then
               target, err = resolve_conflict(name, version, target)
               if err then return nil, err.." Cannot install new version." end
            end
            ok, err = move_fn(source, target)
            if not ok then return nil, err end
         end
      end
      return true
   end
   
   local rock_manifest = manif.load_rock_manifest(name, version)
   
   local ok, err = true
   if rock_manifest.bin then
      ok, err = deploy_file_tree(rock_manifest.bin, path_bin_dir(name, version), cfg.deploy_bin_dir, install_binary)
   end
   if ok and rock_manifest.lua then
      ok, err = deploy_file_tree(rock_manifest.lua, path.lua_dir(name, version), cfg.deploy_lua_dir)
   end
   if ok and rock_manifest.lib then
      ok, err = deploy_file_tree(rock_manifest.lib, path.lib_dir(name, version), cfg.deploy_lib_dir)
   end
   return ok, err
end

--- Delete a package from the local repository.
-- Version numbers are compared as exact string comparison.
-- @param name string: name of package
-- @param version string: package version in string format
function delete_version(name, version)
   assert(type(name) == "string")
   assert(type(version) == "string")

   local function delete_deployed_file_tree(file_tree, deploy_dir)
      for file, sub in pairs(file_tree) do
         local target = dir.path(deploy_dir, file)
         if type(sub) == "table" then
            local ok, err = delete_deployed_file_tree(sub, target)
            if not ok then return nil, err end
            fs.remove_dir_if_empty(target)
         else
            local versioned = path.versioned_name(target, name, version)
            if fs.exists(versioned) then
               fs.delete(versioned)
            else
               fs.delete(target)
            end
         end
      end
      return true
   end

   local rock_manifest = manif.load_rock_manifest(name, version)
   if not rock_manifest then
      return nil, "rock_manifest file not found for "..name.." "..version.." - not a LuaRocks 2 tree?"
   end
   
   local ok, err = true
   if rock_manifest.bin then
      ok, err = delete_deployed_file_tree(rock_manifest.bin, cfg.deploy_bin_dir)
   end
   if ok and rock_manifest.lua then
      ok, err = delete_deployed_file_tree(rock_manifest.lua, cfg.deploy_lua_dir)
   end
   if ok and rock_manifest.lib then
      ok, err = delete_deployed_file_tree(rock_manifest.lib, cfg.deploy_lib_dir)
   end
   if err then return nil, err end

   fs.delete(path.install_dir(name, version))
   if not get_versions(name) then
      fs.delete(dir.path(cfg.rocks_dir, name))
   end
   return true
end
