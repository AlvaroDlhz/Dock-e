//
//  Copyright (C) 2011-2012 Robert Dyer, Rico Tzschichholz
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
	 * If/How the dock should hide itself.
	 */
	public enum HideType
	{
		/**
		 * The dock does not hide.  It should set struts to reserve space for it.
		 */
		NONE,
		/**
		 * The dock hides if a window in the active window group overlaps it.
		 */
		INTELLIGENT,
		/**
		 * The dock hides if the mouse is not over it.
		 */
		AUTO,
		/**
		 * The dock hides if there is an active maximized window.
		 */
		DODGE_MAXIMIZED,
		/**
		 * The dock hides if there is any window overlapping it.
		 */
		WINDOW_DODGE,
		/**
		 * The dock hides if there is the active window overlapping it.
		 */
		DODGE_ACTIVE,
	}
	
	/**
	 * Handles checking if a dock should hide or not.
	 */
	public class HideManager : GLib.Object
	{
		// a delay between window changes and updating our data
		// this allows window animations to occur, which might change
		// the results of our update
		const uint UPDATE_TIMEOUT = 200U;
		
		// FIXME Use an IconSize-based value?
		const double PRESSURE_THRESHOLD = 60.0;
		const uint PRESSURE_TIMEOUT = 1000U;
		
		static int plank_pid;
		
		static construct
		{
			plank_pid = getpid ();
		}
		
		public DockController controller { private get; construct; }
		
		/**
		 * If the dock is currently hidden.
		 */
		public bool Hidden { get; private set; default = true; }
		
		/**
		 * If hiding the dock is currently disabled
		 */
		public bool Disabled { get; private set; default = false; }
		
		/**
		 * If the dock is currently hovered by the mouse cursor.
		 */
		public bool Hovered { get; private set; default = false; }

		/** Keep the dock visible while a menu owned by another dock window is open. */
		public bool ExternalMenuVisible { get; set; default = false; }
		
		uint hide_timer_id = 0U;
		uint unhide_timer_id = 0U;
		uint prefs_changed_timer_id = 0U;
		uint geometry_timer_id = 0U;
		uint window_changed_timer_id = 0U;
		
		bool pointer_update = true;
		bool window_intersect = false;
		bool active_window_intersect = false;
		bool active_application_intersect = false;
		bool active_maximized_window_intersect = false;
		bool dialog_windows_intersect = false;
		Gdk.Rectangle last_window_rect;
		
		Platform.EdgeTrigger? edge_trigger = null;
		Platform.ToplevelManager? toplevels = null;
		Platform.WorkspaceManager? workspaces = null;
		Platform.Toplevel? watched_window = null;
		double pressure = 0.0;
		uint pressure_timer_id = 0U;
		
		/**
		 * Creates a new instance of a HideManager, which handles
		 * checking if a dock should hide or not.
		 *
		 * @param controller the {@link DockController} to manage hiding for
		 */
		public HideManager (DockController controller)
		{
			GLib.Object (controller : controller);
		}
		
		construct
		{
			controller.prefs.notify.connect (prefs_changed);
		}
		
		/**
		 * Initializes the hide manager.  Call after the DockWindow is constructed.
		 */
		public void initialize ()
			requires (controller.window != null)
		{
			unowned DockWindow window = controller.window;
			unowned Platform.Backend? backend = Platform.get_backend ();
			
			initialize_edge_trigger ();
			
			window.enter_notify_event.connect (handle_enter_notify_event);
			window.leave_notify_event.connect (handle_leave_notify_event);
			
			if (backend == null)
				return;
			
			toplevels = backend.toplevels;
			workspaces = backend.workspaces;
			
			toplevels.added.connect (handle_toplevels_changed);
			toplevels.removed.connect (handle_toplevels_changed);
			toplevels.active_changed.connect (handle_active_window_changed);
			if (workspaces != null)
				workspaces.active_changed.connect (handle_workspace_changed);
			
			setup_active_window ();
		}
		
		~HideManager ()
		{
			unowned DockWindow window = controller.window;
			
			controller.prefs.notify.disconnect (prefs_changed);
			
			window.enter_notify_event.disconnect (handle_enter_notify_event);
			window.leave_notify_event.disconnect (handle_leave_notify_event);
			
			if (toplevels != null) {
				toplevels.added.disconnect (handle_toplevels_changed);
				toplevels.removed.disconnect (handle_toplevels_changed);
				toplevels.active_changed.disconnect (handle_active_window_changed);
			}
			if (workspaces != null)
				workspaces.active_changed.disconnect (handle_workspace_changed);
			unwatch_active_window ();
			
			stop_timers ();
			
			if (edge_trigger != null) {
				edge_trigger.hit.disconnect (handle_edge_hit);
				edge_trigger.left.disconnect (handle_edge_left);
				edge_trigger.clear ();
				edge_trigger = null;
			}
		}
		
		/**
		 * Checks to see if the dock is being hovered by the mouse cursor.
		 */
		public void update_hovered ()
		{
			unowned PositionManager position_manager = controller.position_manager;
			unowned DockWindow window = controller.window;
			
			// get current mouse pointer location
			int x, y;
			
			window.get_display ().
				get_device_manager ().get_client_pointer ().get_position (null, out x, out y);
			
			// get window location
			var win_rect = position_manager.get_dock_window_region ();
			x -= win_rect.x;
			y -= win_rect.y;
			
			update_hovered_with_coords (x, y);
		}
		
		/**
		 * Checks to see if the dock is being hovered by the mouse cursor.
		 *
		 * @param x the x coordinate of the pointer relative to the dock window
		 * @param y the y coordinate of the pointer relative to the dock window
		 */
		public void update_hovered_with_coords (int x, int y)
		{
			unowned PositionManager position_manager = controller.position_manager;
			unowned DockWindow window = controller.window;
			unowned DragManager drag_manager = controller.drag_manager;
			
			freeze_notify ();
			
			bool update_needed = false;
			
			// compute rect of the window
			var dock_rect = position_manager.get_cursor_region ();
			
			// use the dock rect and cursor location to determine if dock is hovered
			var hovered = ExternalMenuVisible
				|| (x >= dock_rect.x && x < dock_rect.x + dock_rect.width
				&& y >= dock_rect.y && y < dock_rect.y + dock_rect.height);
			if (Hovered != hovered) {
				Hovered = hovered;
				update_needed = true;
			}
			
			// disable hiding if menu is visible or drags are active
			var disabled = (window.menu_is_visible () || ExternalMenuVisible
				|| drag_manager.InternalDragActive || drag_manager.ExternalDragActive);
			if (Disabled != disabled) {
				Disabled = disabled;
				update_needed = true;
			}
			
			if (update_needed)
				update_hidden ();
			
			thaw_notify ();
		}
		
		void prefs_changed (Object prefs, ParamSpec prop)
		{
			switch (prop.name) {
			case "HideMode":
			case "Position":
				if (prefs_changed_timer_id > 0U) {
					GLib.Source.remove (prefs_changed_timer_id);
					prefs_changed_timer_id = 0U;
				}
				
				prefs_changed_timer_id = Gdk.threads_add_timeout (UPDATE_TIMEOUT, () => {
					update_window_intersect ();
					update_barrier ();
					prefs_changed_timer_id = 0U;
					return false;
				});
				break;
			case "PressureReveal":
				update_barrier ();
				break;
			default:
				// Nothing important for us changed
				break;
			}
		}
		
		void update_hidden ()
		{
			if (Disabled) {
				if (Hidden)
					Hidden = false;
				return;
			}
			
			switch (controller.prefs.HideMode) {
			default:
			case HideType.NONE:
				show ();
				break;
			
			case HideType.INTELLIGENT:
				if (Hovered || !active_application_intersect)
					show ();
				else
					hide ();
				break;
			
			case HideType.AUTO:
				if (Hovered)
					show ();
				else
					hide ();
				break;
			
			case HideType.DODGE_MAXIMIZED:
				if (Hovered || !(active_maximized_window_intersect || dialog_windows_intersect))
					show ();
				else
					hide ();
				break;
			
			case HideType.WINDOW_DODGE:
				if (Hovered || !window_intersect)
					show ();
				else
					hide ();
				break;
			
			case HideType.DODGE_ACTIVE:
				if (Hovered || !active_window_intersect)
					show ();
				else
					hide ();
				break;
			}
			pointer_update = true;
		}
		
		void hide ()
		{
			if (unhide_timer_id > 0U) {
				GLib.Source.remove (unhide_timer_id);
				unhide_timer_id = 0U;
			}
			
			if (Hidden)
				return;
			
			if (controller.prefs.HideDelay == 0U) {
				if (!Hidden)
					Hidden = true;
				return;
			}
			
			if (hide_timer_id > 0U)
				return;
			
			hide_timer_id = Gdk.threads_add_timeout (controller.prefs.HideDelay, () => {
				if (!Hidden)
					Hidden = true;
				hide_timer_id = 0U;
				return false;
			});
		}

		void show ()
		{
			if (hide_timer_id > 0U) {
				GLib.Source.remove (hide_timer_id);
				hide_timer_id = 0U;
			}
			
			if (!Hidden)
				return;
			
			if (!pointer_update || controller.prefs.UnhideDelay == 0U) {
				if (Hidden)
					Hidden = false;
				return;
			}
			
			if (unhide_timer_id > 0U)
				return;
			
			unhide_timer_id = Gdk.threads_add_timeout (controller.prefs.UnhideDelay, () => {
				if (Hidden)
					Hidden = false;
				unhide_timer_id = 0U;
				return false;
			});
		}
		
		[CCode (instance_pos = -1)]
		bool handle_enter_notify_event (Gtk.Widget widget, Gdk.EventCrossing event)
		{
			if (event.detail == Gdk.NotifyType.INFERIOR)
				return Hidden;
			
			if (Hidden && edge_trigger != null
				&& controller.prefs.PressureReveal
				&& device_supports_pressure (event.get_source_device ()))
				return Hidden;
			
			if (!Hovered)
				update_hovered_with_coords ((int) event.x, (int) event.y);
			
			return Hidden;
		}
		
		[CCode (instance_pos = -1)]
		bool handle_leave_notify_event (Gtk.Widget widget, Gdk.EventCrossing event)
		{
			if (event.detail == Gdk.NotifyType.INFERIOR)
				return Gdk.EVENT_PROPAGATE;
			
			// ignore this event if it was sent explicitly
			if ((bool) event.send_event)
				return Gdk.EVENT_PROPAGATE;
			
			if (Hovered)
				update_hovered_with_coords (-1, -1);
			
			return Gdk.EVENT_PROPAGATE;
		}
		
		inline bool device_supports_pressure (Gdk.Device device)
		{
			return (device.input_source == Gdk.InputSource.MOUSE
				|| device.input_source == Gdk.InputSource.TOUCHPAD);
		}
		
		//
		// intelligent hiding code
		//
		
		void update_window_intersect ()
		{
			WindowOverlap overlap = {};
			
			if (toplevels != null)
				overlap = WindowOverlap.compute (toplevels, workspaces,
					controller.position_manager.get_static_dock_region (), plank_pid);
			
			window_intersect = overlap.any_window;
			dialog_windows_intersect = overlap.dialog_window;
			active_application_intersect = overlap.active_application;
			active_window_intersect = overlap.active_window;
			active_maximized_window_intersect = overlap.active_maximized_window;
			
			pointer_update = false;
			update_hidden ();
		}
		
		void schedule_update ()
		{
			if (window_changed_timer_id > 0U)
				return;
			
			window_changed_timer_id = Gdk.threads_add_timeout (UPDATE_TIMEOUT, () => {
				update_window_intersect ();
				window_changed_timer_id = 0U;
				return false;
			});
		}
		
		void handle_toplevels_changed (Platform.Toplevel toplevel)
		{
			schedule_update ();
		}
		
		void handle_workspace_changed (Platform.Workspace? previous)
		{
			schedule_update ();
		}
		
		void handle_active_window_changed (Platform.Toplevel? previous)
		{
			setup_active_window ();
		}
		
		void unwatch_active_window ()
		{
			if (watched_window == null)
				return;
			
			watched_window.geometry_changed.disconnect (handle_geometry_changed);
			watched_window.state_changed.disconnect (handle_state_changed);
			watched_window = null;
		}
		
		void setup_active_window ()
		{
			unwatch_active_window ();
			
			watched_window = toplevels.active;
			
			if (watched_window != null) {
				last_window_rect = window_geometry (watched_window);
				watched_window.geometry_changed.connect (handle_geometry_changed);
				watched_window.state_changed.connect (handle_state_changed);
			}
			
			schedule_update ();
		}
		
		void handle_state_changed (Platform.ToplevelState changed_mask)
		{
			if (!(Platform.ToplevelState.MINIMIZED in changed_mask))
				return;
			
			schedule_update ();
		}
		
		void handle_geometry_changed ()
		{
			var geo = window_geometry (watched_window);
			if (geo == last_window_rect)
				return;
			
			last_window_rect = geo;
			
			if (geometry_timer_id > 0U)
				return;
			
			geometry_timer_id = Gdk.threads_add_timeout (UPDATE_TIMEOUT, () => {
				update_window_intersect ();
				geometry_timer_id = 0U;
				return false;
			});
		}
		
		static Gdk.Rectangle window_geometry (Platform.Toplevel window)
		{
			Gdk.Rectangle win_rect;
			if (!window.get_geometry (out win_rect))
				win_rect = {};
			return win_rect;
		}
		
		void stop_timers ()
		{
			if (geometry_timer_id > 0U) {
				GLib.Source.remove (geometry_timer_id);
				geometry_timer_id = 0U;
			}
			
			if (window_changed_timer_id > 0U) {
				GLib.Source.remove (window_changed_timer_id);
				window_changed_timer_id = 0U;
			}
			
			if (prefs_changed_timer_id > 0U) {
				GLib.Source.remove (prefs_changed_timer_id);
				prefs_changed_timer_id = 0U;
			}
			
			if (hide_timer_id > 0U) {
				GLib.Source.remove (hide_timer_id);
				hide_timer_id = 0U;
			}
			
			if (unhide_timer_id > 0U) {
				GLib.Source.remove (unhide_timer_id);
				unhide_timer_id = 0U;
			}
		}
		
		void initialize_edge_trigger ()
		{
			unowned Platform.Backend? backend = Platform.get_backend ();
			if (backend == null)
				return;
			
			edge_trigger = backend.create_edge_trigger (controller.window);
			if (edge_trigger == null)
				return;
			
			edge_trigger.hit.connect (handle_edge_hit);
			edge_trigger.left.connect (handle_edge_left);
		}
		
		void handle_edge_hit (double dx, double dy, uint32 time)
		{
			double slide = 0.0, distance = 0.0;
			switch (controller.position_manager.Position) {
			default:
			case Gtk.PositionType.BOTTOM:
			case Gtk.PositionType.TOP:
				distance = Math.fabs (dy);
				slide = Math.fabs (dx);
				break;
			case Gtk.PositionType.LEFT:
			case Gtk.PositionType.RIGHT:
				distance = Math.fabs (dx);
				slide = Math.fabs (dy);
				break;
			}
			
			if (slide < distance) {
				distance = Math.fmin (15.0, distance);
				pressure += distance;
				Logger.verbose ("HideManager (pressure = %f)", pressure);
			}
			
			if (pressure >= PRESSURE_THRESHOLD) {
				pressure = 0.0;
				
				if (pressure_timer_id > 0U) {
					GLib.Source.remove (pressure_timer_id);
					pressure_timer_id = 0U;
				}
				
				Logger.verbose ("HideManager (pressure-threshold reached > unhide (%f))", PRESSURE_THRESHOLD);
				
				freeze_notify ();
				
				if (!Hovered) {
					Hovered = true;
					update_hidden ();
				}
				
				thaw_notify ();
			}
		}
		
		void handle_edge_left ()
		{
			if (pressure_timer_id == 0U)
				pressure_timer_id = Gdk.threads_add_timeout (PRESSURE_TIMEOUT, () => {
					pressure = 0.0;
					pressure_timer_id = 0U;
					return false;
				});
		}
		
		public void update_barrier ()
		{
			if (edge_trigger == null)
				return;
			
			edge_trigger.clear ();
			
			if (!controller.prefs.PressureReveal)
				return;
			
			if (controller.prefs.HideMode == HideType.NONE)
				return;
			
			edge_trigger.set_edge (controller.position_manager.Position, controller.position_manager.get_barrier ());
		}
	}
}
