PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_instance_settings` (
	`id` integer PRIMARY KEY DEFAULT 1 NOT NULL,
	`instance_name` text DEFAULT 'Patogh',
	`worker_id` integer,
	`instance_id` text,
	`discovery_enabled` integer DEFAULT 1 NOT NULL,
	`max_bitrate_kbps` integer DEFAULT 20000 NOT NULL,
	`min_bitrate_kbps` integer DEFAULT 500 NOT NULL,
	`bitrate_step_kbps` integer DEFAULT 500 NOT NULL,
	`allowed_resolutions` text DEFAULT '540,720,1080' NOT NULL,
	`allowed_framerates` text DEFAULT '30,45,60' NOT NULL,
	`max_resolution` integer DEFAULT 1080 NOT NULL,
	`max_framerate` integer DEFAULT 60 NOT NULL,
	`registration_open` integer,
	`federated_registration_open` integer DEFAULT 1 NOT NULL,
	`gif_api_key` text,
	`bitrate_matrix_overrides` text,
	`allow_custom_bitrate` integer DEFAULT 1 NOT NULL,
	`max_upload_size_bytes` integer,
	`federation_relay_enabled` integer DEFAULT 1 NOT NULL,
	`federation_relay_ttl_days` integer DEFAULT 30 NOT NULL,
	`default_auto_rotate_interval_days` integer DEFAULT 90 NOT NULL,
	`auto_accept_peering` integer DEFAULT 1 NOT NULL,
	`directory_enabled` integer DEFAULT 0 NOT NULL,
	`directory_dirty` integer DEFAULT 0 NOT NULL,
	`directory_last_ping_at` integer,
	`directory_last_error` text,
	`directory_browse_enabled` integer DEFAULT 1 NOT NULL,
	`support_card_enabled` integer DEFAULT true NOT NULL,
	`installed_at` integer,
	`owner_user_id` text,
	`main_space_id` text,
	`ledger_started_at` integer,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
INSERT INTO `__new_instance_settings`("id", "instance_name", "worker_id", "instance_id", "discovery_enabled", "max_bitrate_kbps", "min_bitrate_kbps", "bitrate_step_kbps", "allowed_resolutions", "allowed_framerates", "max_resolution", "max_framerate", "registration_open", "federated_registration_open", "gif_api_key", "bitrate_matrix_overrides", "allow_custom_bitrate", "max_upload_size_bytes", "federation_relay_enabled", "federation_relay_ttl_days", "default_auto_rotate_interval_days", "auto_accept_peering", "directory_enabled", "directory_dirty", "directory_last_ping_at", "directory_last_error", "directory_browse_enabled", "support_card_enabled", "installed_at", "owner_user_id", "main_space_id", "ledger_started_at", "updated_at") SELECT "id", "instance_name", "worker_id", "instance_id", "discovery_enabled", "max_bitrate_kbps", "min_bitrate_kbps", "bitrate_step_kbps", "allowed_resolutions", "allowed_framerates", "max_resolution", "max_framerate", "registration_open", "federated_registration_open", "gif_api_key", "bitrate_matrix_overrides", "allow_custom_bitrate", "max_upload_size_bytes", "federation_relay_enabled", "federation_relay_ttl_days", "default_auto_rotate_interval_days", "auto_accept_peering", "directory_enabled", "directory_dirty", "directory_last_ping_at", "directory_last_error", "directory_browse_enabled", "support_card_enabled", "installed_at", "owner_user_id", "main_space_id", "ledger_started_at", "updated_at" FROM `instance_settings`;--> statement-breakpoint
DROP TABLE `instance_settings`;--> statement-breakpoint
ALTER TABLE `__new_instance_settings` RENAME TO `instance_settings`;--> statement-breakpoint
PRAGMA foreign_keys=ON;