//
//  Copyright (C) 2011 Robert Dyer
//
//  This file is part of Plank.
//
//  Plank is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Plank is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

namespace Plank
{
	/**
	 * A utility class for launching applications and opening files/URIs.
	 */
	public class System : GLib.Object
	{
		static System? instance = null;
		Gtk.MessageDialog? launch_error_dialog;
		
		public static unowned System get_default ()
		{
			if (instance == null)
				instance = new System (Gdk.Display.get_default ().get_app_launch_context ());
			
			return instance;
		}
		
		public AppLaunchContext context { get; construct; }
		
		public System (AppLaunchContext context)
		{
			Object (context: context);
		}
		
		construct
		{
			context.launch_failed.connect (on_launch_failed);
			context.launched.connect (on_launched);
		}
		
		~System ()
		{
			context.launch_failed.disconnect (on_launch_failed);
			context.launched.disconnect (on_launched);
			if (launch_error_dialog != null)
				launch_error_dialog.destroy ();
		}
		
		void on_launch_failed (string startup_notify_id) 
		{
			report_launch_failure ("Failed to launch '%s'".printf (startup_notify_id));
		}

		internal void report_launch_failure (string technical_message)
		{
			warning ("Unable to open requested item: %s", technical_message);
			if (Gdk.Display.get_default () == null)
				return;
			if (launch_error_dialog != null) {
				launch_error_dialog.present ();
				return;
			}
			var dialog = new Gtk.MessageDialog (null, (Gtk.DialogFlags) 0,
				Gtk.MessageType.ERROR, Gtk.ButtonsType.CLOSE,
				_("The selected item could not be opened."));
			dialog.format_secondary_text (_("Check that the application or file is still available, then try again."));
			dialog.set_keep_above (true);
			dialog.skip_taskbar_hint = true;
			dialog.window_position = Gtk.WindowPosition.CENTER;
			launch_error_dialog = dialog;
			dialog.response.connect (() => {
				launch_error_dialog = null;
				dialog.destroy ();
			});
			dialog.show_all ();
			dialog.present ();
		}
		
		void on_launched (AppInfo info, Variant platform_data)
		{
			Logger.verbose ("Launched '%s' ('%s')", info.get_name (), info.get_executable ());
		}
		
		/**
		 * Opens a file based on a URI.
		 *
		 * @param uri the URI to open
		 */
		public void open_uri (string uri)
		{
			open (File.new_for_uri (uri));
		}
		
		/**
		 * Opens a file based on a {@link GLib.File}.
		 *
		 * @param file the {@link GLib.File} to open
		 */
		public void open (File file)
		{
			launch_with_files (null, { file });
		}
		
		/**
		 * Opens multiple files based on {@link GLib.File}.
		 *
		 * @param files the {@link GLib.File}s to open
		 */
		public void open_files (File[] files)
		{
			launch_with_files (null, files);
		}
		
		/**
		 * Launches an application.
		 *
		 * @param app the application to launch
		 */
		public void launch (File app)
		{
			launch_with_files (app, new File[] {});
		}
		
		/**
		 * Launches an application and opens files.
		 *
		 * @param app the application to launch
		 * @param files the files to open with the application
		 */
		public void launch_with_files (File? app, File[] files)
		{
			if (app != null && !app.query_exists ()) {
				report_launch_failure ("Application '%s' doesn't exist".printf (app.get_path () ?? ""));
				return;
			}
			
			var mounted_files = new GLib.List<File> ();
			
			// make sure all files are mounted
			foreach (var f in files) {
				var path = f.get_path ();
				if (path != null && path != "" && (f.is_native () || path_is_mounted (path))) {
					mounted_files.append (f);
					continue;
				}
				
				try {
					AppInfo.launch_default_for_uri (f.get_uri (), context);
				} catch {
					f.mount_enclosing_volume.begin (0, null);
					mounted_files.append (f);
				}
			}
			
			if (mounted_files.length () > 0 || files.length == 0)
				internal_launch (app, mounted_files);
		}
		
		static bool path_is_mounted (string path)
		{
			foreach (var m in VolumeMonitor.get ().get_mounts ()) {
				var m_root = m.get_root ();
				if (m_root == null)
					continue;
				
				var m_path = m_root.get_path ();
				if (m_path != null && path.contains (m_path))
					return true;
			}
			
			return false;
		}
		
		void internal_launch (File? app, GLib.List<File> files)
		{
			if (app == null && files.length () == 0)
				return;
			
			AppInfo? info = null;
			
			if (app != null) {
				KeyFile keyfile;
				var launcher = app.get_path ();
				
				try {
					keyfile = new KeyFile ();
					keyfile.load_from_file (launcher, KeyFileFlags.NONE);
				} catch (Error e) {
					report_launch_failure ("%s: %s".printf (launcher, e.message));
					return;
				}
				
				try {
					var type = keyfile.get_string (KeyFileDesktop.GROUP, KeyFileDesktop.KEY_TYPE);
					switch (type) {
					default:
					case KeyFileDesktop.TYPE_APPLICATION:
					case KeyFileDesktop.TYPE_DIRECTORY:
						break;
					case KeyFileDesktop.TYPE_LINK:
						try {
							var url = keyfile.get_string (KeyFileDesktop.GROUP, KeyFileDesktop.KEY_URL);
							AppInfo.launch_default_for_uri (url, context);
						} catch (Error e) {
							report_launch_failure ("%s: %s".printf (launcher, e.message));
						}
						return;
					}
				} catch (KeyFileError e) {
					report_launch_failure ("%s: %s".printf (launcher, e.message));
					return;
				}
				
				info = new DesktopAppInfo.from_filename (launcher);
			} else {
				try {
					info = files.first ().data.query_default_handler ();
				} catch (Error e) {
					report_launch_failure (e.message);
				}
			}
			
			if (info == null) {
				report_launch_failure ("Unable to use application/file '%s' for execution.".printf (
					app != null ? app.get_path () : files.first ().data.get_path ()));
				return;
			}
			
			try {
				Logger.verbose ("Launch '%s' ('%s')", info.get_name (), info.get_executable ());
				
				if (files.length () == 0) {
					info.launch (null, context);
					return;
				}
				
				if (info.supports_files ()) {
					info.launch (files, context);
					return;
				}
				
				if (info.supports_uris ()) {
					var uris = new GLib.List<string> ();
					foreach (var f in files)
						uris.append (f.get_uri ());
					info.launch_uris (uris, context);
					return;
				}
				
				report_launch_failure ("The application '%s' doesn't support files/URIs or wasn't found."
					.printf (info.get_name ()));
			} catch (Error e) {
				report_launch_failure (e.message);
			}
		}
	}
}
