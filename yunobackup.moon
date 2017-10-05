#!/usr/bin/env moon

---
-- TODO:
--
--  - prune (file rotation)
--  - remote copies
--  - per-service UI
---

CONFIGURATION_DIRECTORY = "/etc/yunobackup"
BACKUPS_DIRECTORY = "/var/backups"
KEY_FILE = "/etc/yunobackup/key"

lfs = require "lfs"
moonscript = require "moonscript"
process = require "process"
posix = require "posix"
argparse = require "argparse"

Context = class
	new: =>
		@services = {}

	importConfiguration: =>
		success, dir, data = pcall -> lfs.dir CONFIGURATION_DIRECTORY

		unless success
			io.stderr\write dir\gsub("^[^:]*:[^:]*: ", ""), "\n"
			os.exit 1

		for entry in dir, data
			switch entry
				when ".", ".."
					continue

			unless entry\match "%.moon$"
				continue

			filePath = CONFIGURATION_DIRECTORY .. "/" .. entry

			f = moonscript.loadfile filePath

			table.insert @services, f!

		keyFile, reason, b = io.open KEY_FILE, "r"
		if keyFile
			@key = keyFile\read "*line"
			keyFile\close!
		else
			-- FIXME: I’m not sure that error will always be the same (localization?)
			if reason != "#{KEY_FILE}: No such file or directory"
				io.stderr\write reason, "\n"
				os.exit 1
			else
				generator = io.popen "cat /dev/urandom | base64 | head -c 64", "r"
				@key = generator\read "*line"
				generator\close!

				keyFile, reason = io.open KEY_FILE, "w"
				unless keyFile
					io.stderr\write reason, "\n"
					os.exit 1
				keyFile\write @key
				keyFile\close!

	getServiceByName: (name) =>
		for service in *@services
			if service.name == name
				return service

	save: (name) =>
		mkdir = process.exec "mkdir", {"-p", BACKUPS_DIRECTORY}
		result = process.waitpid mkdir\pid!
		unless result.exit == 0
			io.stderr\write mkdir\stderr!
			os.exit 1

		dateProcess = io.popen "date +'%F_%T'", "r"
		date = dateProcess\read "*line"
		dateProcess\close!

		services = if name
			{@\getServiceByName name}
		else
			@services

		posix.setenv "BORG_PASSPHRASE", @key

		for service in *@services
			print service.name
			backupDirectory = BACKUPS_DIRECTORY .. "/" .. service.name
			unless lfs.attributes backupDirectory
				borg = process.exec "borg", {"init", backupDirectory}
				process.waitpid borg\pid!

			args = {"create", "--compression", "lz4", backupDirectory .. "::" .. date}

			for file in *(service.files or {})
				print "file:", file
				table.insert args, file

			for script in *(service.scripts or {})
				print "script:", script
				scriptProcess = io.popen script, "r"
				for file in scriptProcess\lines!
					print "file:", "... " .. file
					table.insert args, file
				scriptProcess\close!

			borg = process.exec "borg", args
			result = process.waitpid borg\pid!

			if result.exit != 0
				io.stderr\write borg\stderr!, "\n"

	list: =>
		for service in *@services
			print service.name

arg = do
	parser = with argparse "yunobackup"
		with \command "list"
			with \argument "service"
				\args "?"
		with \command "borg"
			with \argument "arguments"
				\args "*"
		\command "save"

	parser\parse!

context = with Context!
	\importConfiguration!

	if arg.save
		\save!
	elseif arg.list
		if arg.service
			backupDirectory = BACKUPS_DIRECTORY .. "/" .. arg.service
			posix.setenv "BORG_PASSPHRASE", .key
			os.execute "borg list '#{backupDirectory}'"
		else
			\list!
	elseif arg.borg
		posix.setenv "BORG_PASSPHRASE", .key
		os.execute "borg #{table.concat ["'#{arg}'" for arg in *arg.arguments], " "}"

