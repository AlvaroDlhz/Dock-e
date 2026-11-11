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
	 * Handles all of the drawing for a dock.
	 */
	public class DockRenderer : Renderer
	{
		const double CLOSED_APPLICATION_OPACITY = 0.60;
		const double CENTRAL_ITEM_HOVER_LIFT = 3.0;
		// How far the hover zoom reaches around the pointer, in icons
		const double HOVER_ZOOM_REACH = 2.0;
		// The springs moving the icons: seconds to respond, and how little they bounce
		const double HOVER_SPRING_RESPONSE = 0.17;
		const double HOVER_SPRING_DAMPING = 0.74;
		const double PRESS_SPRING_RESPONSE = 0.15;
		const double PRESS_SPRING_DAMPING = 0.55;
		// How much an icon shrinks while it is pressed
		const double PRESS_SHRINK = 0.12;
		// A click shorter than this (in microseconds) still shows the whole press
		const int64 PRESS_MIN_TIME = 80 * 1000;
		// The curves used to open and close the gap of an added or removed item.
		// The neighbours moving aside use them too, so they have to stay in step.
		const AnimationMode ITEM_ADD_MODE = AnimationMode.EASE_OUT_CUBIC;
		const AnimationMode ITEM_REMOVE_MODE = AnimationMode.EASE_IN_OUT_CUBIC;
		// How much height is left after each bounce on the dock
		const double BOUNCE_RESTITUTION = 0.4;
		// Pause between repeated attention bounces, in milliseconds
		const uint URGENT_BOUNCE_REPEAT_PAUSE = 700;

		static Color active_indicator_color = { 0.450980, 0.823529, 0.086275, 1.0 };

		public DockController controller { private get; construct; }
		
		public DockTheme theme { get; private set; }
		Color theme_fill_start;
		Color theme_fill_end;
		Color theme_outer_stroke;
		Color theme_inner_stroke;
		
		/**
		 * The current progress [0.0..1.0] of the hide-animation of the dock.
		 */
		[CCode (notify = false)]
		public double hide_progress { get; private set; }
		
		/**
		 * The current opacity of the dock.
		 */
		[CCode (notify = false)]
		double opacity { get; private set; }
		
		/**
		 * Legacy zoom progress. This remains 0; hover scaling is applied per item.
		 */
		[CCode (notify = false)]
		public double zoom_in_progress { get; private set; }
		
		/**
		 * The current local cursor-position on the dock if hovered.
		 */
		[CCode (notify = false)]
		public Gdk.Point local_cursor { get; private set; }

		Surface? main_buffer = null;
		Surface? fade_buffer = null;
		Surface? item_buffer = null;
		Surface? shadow_buffer = null;
		
		Surface? background_buffer = null;
		Gdk.Rectangle background_rect;
		Surface? indicator_buffer = null;
		Surface? urgent_indicator_buffer = null;
		Surface? urgent_glow_buffer = null;
		
		int64 last_hide = 0LL;
		
		bool screen_is_composited = false;
		bool show_notifications = true;
		uint reset_position_manager_timer_id = 0U;
		uint urgent_repeat_timer_id = 0U;
		int64 next_urgent_repeat = 0LL;
		int window_scale_factor = 1;
		bool is_first_frame = true;
		
		ulong gtk_theme_name_changed_handler_id = 0UL;
		
		double dynamic_animation_offset = 0.0;
		
		Gee.ArrayList<unowned DockItem> current_items;
		Gee.HashSet<DockItem> transient_items;
#if BENCHMARK
		Gee.ArrayList<string> benchmark;
#endif
		
		/**
		 * Create a new dock renderer for a dock.
		 *
		 * @param controller the dock controller to manage drawing for
		 * @param window the dock window to be animated
		 */
		public DockRenderer (DockController controller, Gtk.Window window)
		{
			GLib.Object (controller : controller, widget : window);
		}
		
		construct
		{
			transient_items = new Gee.HashSet<DockItem> ();
			current_items = new Gee.ArrayList<unowned DockItem> ();
#if BENCHMARK
			benchmark = new Gee.ArrayList<string> ();
#endif
			controller.prefs.notify.connect (prefs_changed);
			
			load_theme ();
		}
		
		/**
		 * Initializes the renderer.  Call after the DockWindow is constructed.
		 */
		public void initialize ()
			requires (controller.window != null)
		{
			controller.position_manager.update (theme);
			
			controller.window.notify["HoveredItem"].connect (animated_draw);
			controller.hide_manager.notify["Hidden"].connect (hidden_changed);
			controller.hide_manager.notify["Hovered"].connect (hovered_changed);
		}
		
		~DockRenderer ()
		{
			controller.prefs.notify.disconnect (prefs_changed);
			theme.notify.disconnect (theme_changed);
			
			controller.hide_manager.notify["Hidden"].disconnect (hidden_changed);
			controller.hide_manager.notify["Hovered"].disconnect (hovered_changed);
			controller.window.notify["HoveredItem"].disconnect (animated_draw);
			
			if (urgent_repeat_timer_id > 0U) {
				Source.remove (urgent_repeat_timer_id);
				urgent_repeat_timer_id = 0U;
			}
		}
		
		void prefs_changed (Object prefs, ParamSpec prop)
		{
			switch (prop.name) {
			case "Alignment":
			case "IconSize":
			case "ItemsAlignment":
			case "Offset":
			case "Position":
				reset_position_manager ();
				break;
			case "Theme":
				load_theme ();
				break;
			case "CustomBackgroundEnabled":
			case "BackgroundColor":
				apply_background_preferences ();
				reset_buffers ();
				break;
			case "HoverZoomEnabled":
			case "HoverZoomPercent":
			case "LaunchBounceEnabled":
			case "UrgentBounceEnabled":
			case "UrgentBounceRepeat":
			case "AnimationSpeed":
			case "ReduceMotion":
				animated_draw ();
				break;
			default:
				// Nothing important for us changed
				break;
			}
		}
		
		void theme_changed ()
		{
			reset_position_manager ();
		}
		
		void reset_position_manager ()
		{
			// Don't perform an update immediately and summon further
			// update-requests, wait at least 50ms after the last request
			
			if (reset_position_manager_timer_id > 0U)
				Source.remove (reset_position_manager_timer_id);
			
			reset_position_manager_timer_id = Gdk.threads_add_timeout (50, () => {
				reset_position_manager_timer_id = 0U;
				
				reset_buffers ();
				reset_item_buffers ();
				controller.position_manager.update (theme);
				
				return false;
			});
		}
		
		void load_theme ()
		{
			var is_reload = (theme != null);
			
			if (is_reload)
				theme.notify.disconnect (theme_changed);
			
			unowned string name = controller.prefs.Theme;
			if (name == Theme.GTK_THEME_NAME) {
				if (gtk_theme_name_changed_handler_id == 0UL)
					gtk_theme_name_changed_handler_id = Gtk.Settings.get_default ().notify["gtk-theme-name"].connect (load_theme);
			} else if (gtk_theme_name_changed_handler_id > 0UL) {
				SignalHandler.disconnect (Gtk.Settings.get_default (), gtk_theme_name_changed_handler_id);
				gtk_theme_name_changed_handler_id = 0UL;
			}
			
			theme = new DockTheme (name);
			theme.load ("dock");
			theme_fill_start = theme.FillStartColor;
			theme_fill_end = theme.FillEndColor;
			theme_outer_stroke = theme.OuterStrokeColor;
			theme_inner_stroke = theme.InnerStrokeColor;
			apply_background_preferences ();
			theme.notify.connect (theme_changed);
			
			if (is_reload)
				theme_changed ();
		}

		void apply_background_preferences ()
		{
			var fill_start = theme_fill_start;
			var fill_end = theme_fill_end;
			var outer_stroke = theme_outer_stroke;
			var inner_stroke = theme_inner_stroke;

			if (controller.prefs.CustomBackgroundEnabled) {
				Gdk.RGBA selected = {};
				if (selected.parse (controller.prefs.BackgroundColor)) {
					fill_start.red = fill_end.red = selected.red;
					fill_start.green = fill_end.green = selected.green;
					fill_start.blue = fill_end.blue = selected.blue;
					fill_start.alpha = fill_end.alpha = 1.0;
				}
			}

			theme.FillStartColor = fill_start;
			theme.FillEndColor = fill_end;
			theme.OuterStrokeColor = outer_stroke;
			theme.InnerStrokeColor = inner_stroke;
		}
		
		/**
		 * Resets all internal buffers and forces a redraw.
		 */
		public void reset_buffers ()
		{
			Logger.verbose ("DockRenderer.reset_buffers ()");
			
			main_buffer = null;
			fade_buffer = null;
			item_buffer = null;
			shadow_buffer = null;
			
			background_buffer = null;
			indicator_buffer = null;
			urgent_indicator_buffer = null;
			urgent_glow_buffer = null;
			
			animated_draw ();
		}
		
		/**
		 * Resets all internal item buffers and forces a redraw.
		 */
		void reset_item_buffers ()
		{
			Logger.verbose ("DockRenderer.reset_item_buffers ()");
			
			controller.reset_buffers ();
			
			animated_draw ();
		}
		
		/**
		 * {@inheritDoc}
		 */
		protected override void initialize_frame (int64 frame_time)
		{
			return_if_fail (theme != null);
			
			unowned Gee.ArrayList<unowned DockItem> new_items = controller.VisibleItems;
			
			// FIXME This should never happen
			if (new_items.size <= 0) {
				critical ("No items available to initialize frame");
				return;
			}
			
			unowned PositionManager position_manager = controller.position_manager;
			
			screen_is_composited = position_manager.screen_is_composited;
			show_notifications = EnvironmentSettings.get_instance ().ShowNotifications;
			dynamic_animation_offset = 0.0;
			
			var fade_opacity = theme.FadeOpacity;
			
			if (screen_is_composited) {
				var hide_length = hide_duration ();
				var hide_time = int64.max (0LL, frame_time - last_hide);
				if (hide_time < hide_length) {
					if (controller.hide_manager.Hidden)
						hide_progress = easing_for_mode (AnimationMode.EASE_IN_CUBIC, hide_time, hide_length);
					else
						hide_progress = 1.0 - easing_for_mode (AnimationMode.EASE_OUT_CUBIC, hide_time, hide_length);
				} else {
					hide_progress = (controller.hide_manager.Hidden ? 1.0 : 0.0);
				}
				
				zoom_in_progress = 0.0;
			} else {
				hide_progress = 0.0;
				zoom_in_progress = 0.0;
			}
			
			if (fade_opacity < 1.0)
				opacity = 1.0 - (1.0 - fade_opacity) * hide_progress;
			else
				opacity = 1.0;

			// Update *ordered* list of items
			current_items.clear ();
			current_items.add_all (new_items);
			
			if (screen_is_composited) {
				var add_time = 0LL;
				var remove_time = 0LL;
				var move_time = 0LL;
				var move_duration = item_move_duration ();
				
				var transient_items_it = transient_items.iterator ();
				while (transient_items_it.next ()) {
					var item = transient_items_it.get ();
					add_time = item.AddTime;
					remove_time = item.RemoveTime;
					
					if (add_time > remove_time) {
						move_time = frame_time - add_time;
						if (move_time < move_duration) {
							if (!current_items.contains (item))
								current_items.add (item);
						} else {
							transient_items_it.remove ();
						}
					} else if (remove_time > 0) {
						move_time = frame_time - remove_time;
						if (move_time < move_duration) {
							if (!current_items.contains (item))
								current_items.add (item);
						} else {
							transient_items_it.remove ();
						}
					}
				}
			} else {
				transient_items.clear ();
			}
			
			current_items.sort ((CompareDataFunc) compare_dock_item_position);
			
			// Calculate positions for given ordered list of items
			position_manager.update_draw_values (current_items,
				(DrawValueFunc) animate_draw_value_for_item,
				(DrawValuesFunc) post_process_draw_values);
			
			background_rect = position_manager.get_background_region ();
		}

		/**
		 * {@inheritDoc}
		 */
		public override void draw (Cairo.Context cr, int64 frame_time)
		{
			// FIXME This should never happen
			if (current_items.size <= 0) {
				critical ("No items available to draw frame");
				return;
			}
			
			window_scale_factor = controller.window.get_window ().get_scale_factor ();
			// take the previous frame values into account to decide if we
			// can bail a full draw to not miss a finishing animation-frame
			var no_full_draw_needed = (!is_first_frame && hide_progress == 1.0 && opacity == 1.0);
			
			unowned PositionManager position_manager = controller.position_manager;
			unowned DockItem dragged_item = controller.drag_manager.DragItem;
			var win_rect = position_manager.get_dock_window_region ();
			
			if (main_buffer == null) {
				main_buffer = new Surface.with_cairo_surface (win_rect.width, win_rect.height, cr.get_target ());
				main_buffer.Internal.set_device_scale (window_scale_factor, window_scale_factor);
			}
			
			if (item_buffer == null) {
				item_buffer = new Surface.with_cairo_surface (win_rect.width, win_rect.height, cr.get_target ());
				item_buffer.Internal.set_device_scale (window_scale_factor, window_scale_factor);
			}
			
			if (shadow_buffer == null) {
				shadow_buffer = new Surface.with_cairo_surface (win_rect.width, win_rect.height, cr.get_target ());
				shadow_buffer.Internal.set_device_scale (window_scale_factor, window_scale_factor);
			}
			
			// if the dock is completely hidden and not transparently drawn
			// only draw ugent-glow indicators and bail since there is no need
			// for further things
			if (no_full_draw_needed && hide_progress == 1.0 && opacity == 1.0) {
				// we still need to clear out the previous output
				cr.save ();
				cr.set_operator (Cairo.Operator.CLEAR);
				cr.paint ();
				cr.restore ();
				
				if (show_notifications)
					foreach (unowned DockItem item in current_items)
						draw_urgent_glow (item, cr, frame_time);
				
				return;
			}

			if (opacity < 1.0 && fade_buffer == null) {
				fade_buffer = new Surface.with_cairo_surface (win_rect.width, win_rect.height, cr.get_target ());
				fade_buffer.Internal.set_device_scale (window_scale_factor, window_scale_factor);
			}
			
#if BENCHMARK
			DateTime start, start2, end, end2;
			benchmark.clear ();
			start = new DateTime.now_local ();
#endif
			
			main_buffer.clear ();
			item_buffer.clear ();
			shadow_buffer.clear ();
			unowned Cairo.Context item_cr = item_buffer.Context;
			unowned Cairo.Context shadow_cr = shadow_buffer.Context;
			
			// calculate drawing offset
			var primary_x_offset = 0, primary_y_offset = 0;
			position_manager.get_dock_draw_position_for_progress (hide_progress,
				out primary_x_offset, out primary_y_offset);
			
			// composite dock layers and make sure to draw onto the window's context with one operation
			main_buffer.clear ();
			unowned Cairo.Context main_cr = main_buffer.Context;
			main_cr.set_operator (Cairo.Operator.OVER);
			
#if BENCHMARK
			start2 = new DateTime.now_local ();
#endif
			draw_dock_background (main_cr, background_rect,
				primary_x_offset, primary_y_offset, hide_progress);
#if BENCHMARK
			end2 = new DateTime.now_local ();
			benchmark.add ("background render time - %f ms".printf (end2.difference (start2) / 1000.0));
#endif
			
			// draw each item onto the dock buffer
			for (var i = 0; i < current_items.size; i++) {
				unowned DockItem item = current_items[i];
#if BENCHMARK
				start2 = new DateTime.now_local ();
#endif
				// Do not draw the currently dragged item
				if (item.IsVisible && dragged_item != item) {
					var draw_value = position_manager.get_draw_value_for_item (item);
					item_cr.save ();
					shadow_cr.save ();
					if (item is LauncherItem)
						draw_item_divider (item_cr, draw_value);
					draw_item (item_cr, item, draw_value, frame_time);
					draw_item_shadow (shadow_cr, item, draw_value);
					item_cr.restore ();
					shadow_cr.restore ();
				}
#if BENCHMARK
				end2 = new DateTime.now_local ();
				benchmark.add ("item render time - %f ms".printf (end2.difference (start2) / 1000.0));
#endif
			}
			
			main_cr.set_source_surface (shadow_buffer.Internal, primary_x_offset, primary_y_offset);
			main_cr.paint ();
			main_cr.set_source_surface (item_buffer.Internal, primary_x_offset, primary_y_offset);
			main_cr.paint ();
			
			// draw the dock on the window and fade it if need be
			cr.set_operator (Cairo.Operator.SOURCE);
			if (opacity < 1.0) {
				fade_buffer.clear ();
				unowned Cairo.Context fade_cr = fade_buffer.Context;
				fade_cr.set_operator (Cairo.Operator.OVER);
				fade_cr.set_source_surface (main_buffer.Internal, 0, 0);
				fade_cr.paint_with_alpha (opacity);
				
				cr.set_source_surface (fade_buffer.Internal, 0, 0);
			} else {
				cr.set_source_surface (main_buffer.Internal, 0, 0);
			}
			cr.paint ();
			
			// draw urgent-glow if dock is completely hidden
			if (show_notifications && hide_progress == 1.0) {
				foreach (unowned DockItem item in current_items)
					draw_urgent_glow (item, cr, frame_time);
			}
			
#if BENCHMARK
			end = new DateTime.now_local ();
			var diff = end.difference (start) / 1000.0;
			if (diff > 5.0)
				foreach (var s in benchmark)
					message ("	" + s);
			message ("render time - %f ms", diff);
#endif
			
			if (is_first_frame) {
				message ("Cairo.SurfaceType: %s", cairo_surface_type_to_string (cr.get_target ().get_type ()));
				
				Gdk.threads_add_idle_full (GLib.Priority.LOW, () => {
					unowned HideManager hide_manager = controller.hide_manager;
					
					// FIXME HideManager.initialize () -> setup_active_window ();
					// is already taking care of updating the Hidden-state,
					// but only if there is already an active/open window
					if (hide_manager.Hidden)
						return false;
					
					// slide the dock in, if it shouldnt start hidden
					hide_manager.update_hovered ();
					
					// FIXME there must be a sane way
					// https://bugs.launchpad.net/plank/+bug/1256626
					force_frame_time_update ();
					last_hide = frame_time;
					
					hidden_changed ();
					return false;
				});
				
				is_first_frame = false;
			}
		}
		
		void draw_dock_background (Cairo.Context cr, Gdk.Rectangle background_rect, int x_offset, int y_offset,
			double hide_progress)
		{
			unowned PositionManager position_manager = controller.position_manager;
			
			if (background_rect.width <= 0 || background_rect.height <= 0) {
				background_buffer = null;
				return;
			}

			Surface? buffer = background_buffer;
			if (buffer == null || buffer.Width != background_rect.width || buffer.Height != background_rect.height) {
				buffer = theme.create_background (background_rect.width, background_rect.height,
					position_manager.Position, main_buffer);
				background_buffer = buffer;
			}
			
			if (hide_progress > 0.0 && theme.CascadeHide) {
				int x, y;
				position_manager.get_background_padding (out x, out y);
				x_offset -= (int) (x * hide_progress);
				y_offset -= (int) (y * hide_progress);
			}
			
			cr.set_source_surface (buffer.Internal, background_rect.x + x_offset, background_rect.y + y_offset);
			cr.paint ();
		}
		
		[CCode (instance_pos = -1)]
		void animate_draw_value_for_item (DockItem item, DockItemDrawValue draw_value)
		{
			unowned PositionManager position_manager = controller.position_manager;
			unowned DockItem hovered_item = controller.window.HoveredItem;
			unowned DragManager drag_manager = controller.drag_manager;
			
			var icon_size = (int) draw_value.icon_size;
			var position = position_manager.Position;
			var x_offset = 0.0, y_offset = 0.0;
			
			// check for and calculate click-animation
			var max_click_time = item_click_duration (item);
			var click_time = int64.max (0LL, frame_time - item.LastClicked);
			if (click_time < max_click_time) {
				var click_animation_progress = click_time / (double) max_click_time;
				
				switch (item.ClickedAnimation) {
				default:
				case AnimationType.NONE:
					break;
				case AnimationType.BOUNCE:
					if (screen_is_composited)
						draw_value.lift += position_manager.LaunchBounceHeight * easing_bounce (click_time, max_click_time, 2);
					break;
				case AnimationType.DARKEN:
					// The press animation already answers the click when icons may move
					if (!is_application_motion_enabled ())
						draw_value.darken = double.max (0, Math.sin (Math.PI * click_animation_progress)) * 0.5;
					break;
				case AnimationType.LIGHTEN:
					draw_value.lighten = double.max (0, Math.sin (Math.PI * click_animation_progress)) * 0.5;
					break;
				}
			}
			
			// check for and calculate scroll-animation
			var max_scroll_time = ITEM_SCROLL_DURATION * 1000;
			var scroll_time = int64.max (0LL, frame_time - item.LastScrolled);
			if (scroll_time < max_scroll_time) {
				var scroll_animation_progress = scroll_time / (double) max_scroll_time;
				
				switch (item.ScrolledAnimation) {
				default:
				case AnimationType.NONE:
					break;
				case AnimationType.DARKEN:
					draw_value.darken = double.max (0, Math.sin (Math.PI * scroll_animation_progress)) * 0.5;
					break;
				case AnimationType.LIGHTEN:
					draw_value.lighten = double.max (0, Math.sin (Math.PI * scroll_animation_progress)) * 0.5;
					break;
				}
			}
			
			// check for and calculate hover-animation
			var max_hover_time = item_hover_duration ();
			var animations_enabled = is_application_motion_enabled ();
			var is_application_item = item is ApplicationDockItem;
			var hovering = (hovered_item == item);
			var hover_animation_progress = (hovering ? 1.0 : 0.0);
			if (is_application_item) {
				if (item.hover_stamp != item.LastHovered) {
					// The pointer just entered or left. Continue from wherever the
					// previous animation got to instead of restarting from its end.
					item.hover_stamp = item.LastHovered;
					var reached = (hovering ? item.hover_value : 1.0 - item.hover_value);
					item.hover_shift = (int64) (Motion.ease_out_cubic_inverse (reached) * max_hover_time);
				}
				
				var hover_time = int64.max (0LL, frame_time - item.LastHovered) + item.hover_shift;
				if (animations_enabled && hover_time < max_hover_time) {
					var eased = easing_for_mode (AnimationMode.EASE_OUT_CUBIC, hover_time, max_hover_time);
					hover_animation_progress = (hovering ? eased : 1.0 - eased);
				}
				item.hover_value = hover_animation_progress;
				
				if (hover_animation_progress > 0.0)
					draw_value.lighten = hover_animation_progress * 0.2;
			}
			// The time passed since this item's springs were last advanced
			var spring_elapsed = frame_time - item.spring_time;
			item.spring_time = frame_time;
			var spring_dt = (spring_elapsed <= 0LL ? 0.0 : int64.min (spring_elapsed, 32000LL) / 1000000.0);
			var spring_speed = application_animation_duration_scale ();
			
			// Icons grow with their distance to the pointer rather than only when
			// it is on them, so the zoom travels along the dock with the pointer
			var zoom_target = 0.0;
			if (is_application_item && animations_enabled && hovered_item != null
				&& controller.prefs.HoverZoomEnabled && controller.prefs.HoverZoomPercent > 100) {
				var cursor = local_cursor;
				var distance = position_manager.is_horizontal_dock ()
					? Math.fabs (cursor.x - draw_value.center.x)
					: Math.fabs (cursor.y - draw_value.center.y);
				var reach = (icon_size + position_manager.ItemPadding) * HOVER_ZOOM_REACH;
				if (distance < reach) {
					var falloff = Math.cos (Math.PI_2 * distance / reach);
					zoom_target = falloff * falloff;
				}
			}
			var zooming = item.zoom_spring.step (zoom_target, spring_dt,
				HOVER_SPRING_RESPONSE * spring_speed, HOVER_SPRING_DAMPING);
			if (!animations_enabled) {
				item.zoom_spring = {};
				zooming = false;
			}
			if (item.zoom_spring.value != 0.0) {
				draw_value.scale *= 1.0
					+ (controller.prefs.HoverZoomPercent / 100.0 - 1.0) * item.zoom_spring.value;
				draw_value.lift += CENTRAL_ITEM_HOVER_LIFT * item.zoom_spring.value;
			}
			
			// Icons give way while pressed and spring back when released
			var press_target = 0.0;
			if (animations_enabled && (controller.window.ClickedItem == item
				|| (item.LastClicked > 0LL && frame_time - item.LastClicked < PRESS_MIN_TIME)))
				press_target = 1.0;
			var pressing = item.press_spring.step (press_target, spring_dt,
				PRESS_SPRING_RESPONSE * spring_speed, PRESS_SPRING_DAMPING);
			if (!animations_enabled) {
				item.press_spring = {};
				pressing = false;
			}
			if (item.press_spring.value != 0.0)
				draw_value.scale *= 1.0 - PRESS_SHRINK * item.press_spring.value;
			
			item.spring_active = (zooming || pressing);
			
			if (is_application_item && hovered_item == item && controller.window.menu_is_visible ())
				draw_value.darken += 0.4;
			else if (drag_manager.ExternalDragActive
				&& drag_manager.DragNeedsCheck
				&& !drag_manager.drop_is_accepted_by (item))
				draw_value.darken += 0.6;
			
			// bounce icon on urgent state
			if (item_urgent_bounce_enabled (item) && (item.State & ItemState.URGENT) != 0) {
				var urgent_duration = urgent_bounce_duration ();
				var urgent_time = int64.max (0LL, frame_time - item.LastUrgent);
				if (controller.prefs.UrgentBounceRepeat)
					urgent_time %= urgent_bounce_cycle_duration ();
				if (urgent_time < urgent_duration)
					draw_value.lift += position_manager.UrgentBounceHeight
						* easing_bounce (urgent_time, urgent_duration, 1.0);
			}
			
			// animate addition/removal
			unowned DockContainer? container = item.Container;
			// Tray expansion is a compact visibility toggle, not a launcher being
			// added to or removed from the dock.  Its icons must appear and disappear
			// immediately instead of using the normal slide/fade transition.
			var is_dynamic_tray_item = item is TrayStatusItem || item is TrayOverflowItem;
			if (is_dynamic_tray_item && item.RemoveTime > 0)
				draw_value.opacity = 0.0;
			var allow_animation = (screen_is_composited && !is_dynamic_tray_item
				&& (container == null || container.AddTime < item.AddTime));
			if (allow_animation && item.AddTime > item.RemoveTime) {
				var move_duration = item_move_duration ();
				var move_time = int64.max (0LL, frame_time - item.AddTime);
				if (move_time < move_duration) {
					// The icon fades and slides in on the same curve that opens its gap
					var move_animation_progress = 1.0 - easing_for_mode (ITEM_ADD_MODE, move_time, move_duration);
					draw_value.opacity = 1.0 - move_animation_progress;
					y_offset -= move_animation_progress * (icon_size + position_manager.BottomPadding);
					draw_value.show_indicator = false;
					
					// calculate the resulting incremental dynamic-animation-offset used to animate the background-resize and icon-offset
					dynamic_animation_offset -= move_animation_progress * (icon_size + position_manager.ItemPadding);
					x_offset += dynamic_animation_offset;
				}
			} else if (allow_animation && item.RemoveTime > 0) {
				var move_duration = item_move_duration ();
				var move_time = int64.max (0LL, frame_time - item.RemoveTime);
				if (move_time < move_duration) {
					// The icon leaves first, its gap closes right behind it
					var move_animation_progress = easing_for_mode (AnimationMode.EASE_OUT_CUBIC, move_time, move_duration);
					draw_value.opacity = 1.0 - move_animation_progress;
					y_offset -= move_animation_progress * (icon_size + position_manager.BottomPadding);
					draw_value.show_indicator = false;
					
					// calculate the resulting incremental dynamic-animation-offset used to animate the background-resize and icon-offset
					move_animation_progress = 1.0 - easing_for_mode (ITEM_REMOVE_MODE, move_time, move_duration);
					dynamic_animation_offset += move_animation_progress * (icon_size + position_manager.ItemPadding);
					x_offset += dynamic_animation_offset - (icon_size + position_manager.ItemPadding);
				}
			}
			
			// animate icon movement on move state
			if (!is_dynamic_tray_item && (item.State & ItemState.MOVE) != 0) {
				var move_duration = item_move_duration ();
				var move_time = int64.max (0LL, frame_time - item.LastMove);
				if (move_time < move_duration) {
					var move_animation_progress = 0.0;
					if (transient_items.size > 0) {
						if (dynamic_animation_offset > 0)
							move_animation_progress = 1.0 - easing_for_mode (ITEM_REMOVE_MODE, move_time, move_duration);
						else
							move_animation_progress = 1.0 - easing_for_mode (ITEM_ADD_MODE, move_time, move_duration);
					} else {
						move_animation_progress = 1.0 - easing_for_mode (AnimationMode.EASE_OUT_CUBIC, move_time, move_duration);
					}
					var change = move_animation_progress * (icon_size + position_manager.ItemPadding);
					x_offset += (item.Position < item.LastPosition ? change : -change);
				} else {
					item.unset_move_state ();
				}
			}
			
			// animate icon on invalid state
			if ((item.State & ItemState.INVALID) != 0) {
				var invalid_duration = ITEM_INVALID_DURATION * 1000;
				var invalid_time = int64.max (0LL, frame_time - item.LastValid);
				if (invalid_time < invalid_duration) {
					draw_value.opacity = 0.10 + (0.90 * (Math.cos (invalid_time / (double) invalid_duration * 4.5 * Math.PI) + 1) / 2);
				} else {
					draw_value.opacity = 0.10;
				}
			}
			
			if (x_offset != 0.0)
				draw_value.move_right (position, x_offset);
			
			if (y_offset != 0.0)
				draw_value.move_in (position, y_offset);
		}
		
		[CCode (instance_pos = -1)]
		void post_process_draw_values (Gee.HashMap<DockElement, DockItemDrawValue?> draw_values)
		{
			if (dynamic_animation_offset == 0.0)
				return;
			
			unowned PositionManager position_manager = controller.position_manager;
			var position = position_manager.Position;
			
			var x_offset = 0.0;
			
			switch (position_manager.Alignment) {
			default:
			case Gtk.Align.CENTER:
				x_offset -= Math.round (dynamic_animation_offset / 2.0);
				break;
			case Gtk.Align.START:
				break;
			case Gtk.Align.END:
				x_offset -= Math.round (dynamic_animation_offset);
				break;
			case Gtk.Align.FILL:
				switch (position_manager.ItemsAlignment) {
				default:
				case Gtk.Align.FILL:
				case Gtk.Align.CENTER:
					x_offset -= Math.round (dynamic_animation_offset / 2.0);
					break;
				case Gtk.Align.START:
					break;
				case Gtk.Align.END:
					x_offset -= Math.round (dynamic_animation_offset);
					break;
				}
				break;
			}
			
			if (x_offset == 0.0)
				return;
			
			draw_values.map_iterator ().foreach ((i, val) => {
				val.move_right (position, x_offset);
				return true;
			});
		}
		
		inline Surface get_item_surface (DockItem item, int icon_width, int icon_size)
		{
			var private_icon_surface = item.get_surface (icon_width, icon_size, item_buffer);
			if (!screen_is_composited)
				return private_icon_surface;
			
			// FIXME There is probably a nicer way to accomplish this
			// Check if the underlying cache returned a marked surface and if needed
			// request another draw with the currently assumed largest required size
			string? drawing_status;
			unowned PositionManager position_manager = controller.position_manager;
			var max_icon_size = position_manager.ZoomIconSize * window_scale_factor;
			var max_icon_width = icon_width > icon_size
				? (int) (icon_width * max_icon_size / (double) icon_size)
				: max_icon_size;
			if (icon_size < max_icon_size
				&& ((drawing_status = private_icon_surface.steal_qdata<string> (quark_surface_stats)) != null
				&& drawing_status == SURFACE_STATS_DRAWING_TIME_EXCEEDED))
				item.get_surface (max_icon_width, max_icon_size, item_buffer);
			
			return private_icon_surface;
		}
		
		double get_item_opacity (DockItem item, DockItemDrawValue draw_value)
		{
			if (is_inactive_item (item))
				return draw_value.opacity * CLOSED_APPLICATION_OPACITY;

			return draw_value.opacity;
		}

		bool is_inactive_item (DockItem item)
		{
			var app_item = item as ApplicationDockItem;
			if (app_item != null)
				return !app_item.is_running ();

			return item is LauncherItem && !controller.launcher.visible;
		}

		void draw_item_divider (Cairo.Context cr, DockItemDrawValue draw_value, double direction = 1.0)
		{
			unowned PositionManager position_manager = controller.position_manager;
			var divider_length = position_manager.IconSize * 0.58;
			var divider_offset = (position_manager.IconSize + position_manager.ItemPadding) / 2.0;
			var background_luminance = theme_fill_start.red * 0.2126
				+ theme_fill_start.green * 0.7152 + theme_fill_start.blue * 0.0722;
			var divider_color = background_luminance > 0.55 ? 0.0 : 1.0;

			cr.save ();
			cr.set_source_rgba (divider_color, divider_color, divider_color, 0.18);
			if (position_manager.is_horizontal_dock ()) {
				cr.rectangle (Math.round (draw_value.center.x + divider_offset * direction),
					Math.round (draw_value.center.y - divider_length / 2.0),
					1.0, Math.round (divider_length));
			} else {
				cr.rectangle (Math.round (draw_value.center.x - divider_length / 2.0),
					Math.round (draw_value.center.y + divider_offset * direction),
					Math.round (divider_length), 1.0);
			}
			cr.fill ();
			cr.restore ();
		}

		void desaturate_icon (Surface icon_surface)
		{
			var source = icon_surface.to_pixbuf ();
			var grayscale = source.copy ();
			source.saturate_and_pixelate (grayscale, 0.0f, false);

			unowned Cairo.Context icon_cr = icon_surface.Context;
			icon_cr.set_operator (Cairo.Operator.SOURCE);
			Gdk.cairo_set_source_pixbuf (icon_cr, grayscale, 0, 0);
			icon_cr.paint ();
			icon_cr.set_operator (Cairo.Operator.OVER);
		}

		void draw_item (Cairo.Context cr, DockItem item, DockItemDrawValue draw_value, int64 frame_time)
		{
			unowned PositionManager position_manager = controller.position_manager;
			// An enlarged icon is rendered at its largest size and scaled down
			// while painting, which keeps it sharp at every size in between
			var render_scale = 1.0;
			if (draw_value.scale > 1.0)
				render_scale = double.max (1.0, controller.prefs.HoverZoomPercent / 100.0);
			var icon_size = (int) (draw_value.icon_size * render_scale) * window_scale_factor;
			var icon_width = (int) (draw_value.icon_width * render_scale) * window_scale_factor;
			var position = position_manager.Position;
			
			// load the icon
#if BENCHMARK
			var start = new DateTime.now_local ();
#endif
			var icon_surface = get_item_surface (item, icon_width, icon_size).copy ();
			unowned Cairo.Context icon_cr = icon_surface.Context;
			
			Surface? icon_overlay_surface = null;
			if (item.CountVisible || item.ProgressVisible)
				icon_overlay_surface = item.get_foreground_surface (icon_width, icon_size, item_buffer, (DrawDataFunc<DockItem>) draw_item_foreground);
			
			if (icon_overlay_surface != null) {
				icon_cr.set_source_surface (icon_overlay_surface.Internal, 0, 0);
				icon_cr.paint ();
			}
			
#if BENCHMARK
			var end = new DateTime.now_local ();
			benchmark.add ("	item.get_surface time - %f ms".printf (end.difference (start) / 1000.0));
#endif
			
			// lighten the icon
			if (draw_value.lighten > 0) {
				icon_cr.set_operator (Cairo.Operator.ADD);
				icon_cr.paint_with_alpha (draw_value.lighten);
				icon_cr.set_operator (Cairo.Operator.OVER);
			}
			
			// darken the icon
			if (draw_value.darken > 0) {
				icon_cr.rectangle (0, 0, icon_surface.Width, icon_surface.Height);
				icon_cr.set_source_rgba (0, 0, 0, draw_value.darken);
				icon_cr.set_operator (Cairo.Operator.ATOP);
				icon_cr.fill ();
				icon_cr.set_operator (Cairo.Operator.OVER);
			}

			if (is_inactive_item (item))
				desaturate_icon (icon_surface);
			
			// draw active glow
			var active_time = int64.max (0LL, frame_time - item.LastActive);
			var opacity = double.min (1, active_time / (double) (theme.ActiveTime * 1000));
			if ((item.State & ItemState.ACTIVE) == 0)
				opacity = 1 - opacity;
			if (opacity > 0) {
				// The indicator grows out of its middle while it fades in
				var extent = easing_for_mode (AnimationMode.EASE_OUT_CUBIC, opacity, 1.0);
				theme.draw_active_glow (item_buffer, background_rect, draw_value.draw_region,
					active_indicator_color, opacity, position,
					item.Indicator == IndicatorState.SINGLE_PLUS, extent);
			}
			
			// draw the icon
			var draw_region = draw_value.draw_region;
			var item_opacity = get_item_opacity (item, draw_value);
			cr.save ();
			if (draw_value.scale != 1.0 || draw_value.lift != 0.0) {
				transform_to_item (cr, draw_value, position);
				var paint_scale = draw_value.scale / (render_scale * window_scale_factor);
				cr.scale (paint_scale, paint_scale);
				cr.set_source_surface (icon_surface.Internal, -icon_width / 2.0, -icon_size / 2.0);
			} else {
				if (window_scale_factor > 1)
					cr.scale (1.0 / window_scale_factor, 1.0 / window_scale_factor);
				cr.set_source_surface (icon_surface.Internal, draw_region.x * window_scale_factor, draw_region.y * window_scale_factor);
			}
			if (item_opacity < 1.0)
				cr.paint_with_alpha (item_opacity);
			else
				cr.paint ();
			cr.restore ();
			
			// draw indicators
			if (!(item is ApplicationDockItem) && draw_value.show_indicator && item.Indicator != IndicatorState.NONE)
				draw_indicator_state (cr, draw_value.hover_region, item.Indicator, item.State);
		}
		
		void draw_item_shadow (Cairo.Context cr, DockItem item, DockItemDrawValue draw_value)
		{
			unowned PositionManager position_manager = controller.position_manager;
			var shadow_size = position_manager.IconShadowSize;
			// Inflate size to fit shadow
			var icon_size = (int) (draw_value.icon_size + 2 * shadow_size) * window_scale_factor;
			var icon_width = (int) (draw_value.icon_width + 2 * shadow_size) * window_scale_factor;
			
			// load and draw the icon shadow
			Surface? icon_shadow_surface = null;
			if (shadow_size > 0)
				icon_shadow_surface = item.get_background_surface (icon_width, icon_size, item_buffer, (DrawDataFunc<DockItem>) draw_item_background);
			
			if (icon_shadow_surface != null) {
				var draw_region = draw_value.draw_region;
				cr.save ();
				cr.set_operator (Cairo.Operator.OVER);
				if (draw_value.scale != 1.0 || draw_value.lift != 0.0) {
					transform_to_item (cr, draw_value, position_manager.Position);
					var paint_scale = draw_value.scale / window_scale_factor;
					cr.scale (paint_scale, paint_scale);
					cr.set_source_surface (icon_shadow_surface.Internal, -icon_width / 2.0, -icon_size / 2.0);
				} else {
					if (window_scale_factor > 1)
						cr.scale (1.0 / window_scale_factor, 1.0 / window_scale_factor);
					cr.set_source_surface (icon_shadow_surface.Internal, (draw_region.x - shadow_size) * window_scale_factor, (draw_region.y - shadow_size) * window_scale_factor);
				}
				var item_opacity = get_item_opacity (item, draw_value);
				if (item_opacity < 1.0)
					cr.paint_with_alpha (item_opacity);
				else
					cr.paint ();
				cr.restore ();
			}
		}

		/**
		 * Moves the origin to the middle of where the item is painted,
		 * including how far it is lifted off the dock.
		 */
		static void transform_to_item (Cairo.Context cr, DockItemDrawValue draw_value, Gtk.PositionType position)
		{
			var draw_region = draw_value.draw_region;
			var x = draw_region.x + draw_region.width / 2.0;
			var y = draw_region.y + draw_region.height / 2.0;
			
			switch (position) {
			default:
			case Gtk.PositionType.BOTTOM: y -= draw_value.lift; break;
			case Gtk.PositionType.TOP: y += draw_value.lift; break;
			case Gtk.PositionType.LEFT: x += draw_value.lift; break;
			case Gtk.PositionType.RIGHT: x -= draw_value.lift; break;
			}
			
			cr.translate (x, y);
		}

		[CCode (instance_pos = -1)]
		Surface draw_item_foreground (int width, int height, Surface model, DockItem item)
		{
			Logger.verbose ("DockItem.draw_item_overlay (width = %i, height = %i)", width, height);
			var surface = new Surface.with_surface (width, height, model);
			
			var icon_size = int.min (width, height);
			var urgent_color = theme.BadgeColor;
			if (urgent_color.equal ({0.0, 0.0, 0.0, 0.0})) {
				urgent_color = get_styled_color ();
				urgent_color.add_hue (theme.UrgentHueShift);
			}
			
			if (item.CountVisible) {
				if (item is TrayToggleItem)
					draw_green_count_badge (surface, icon_size, item.Count);
				else
					theme.draw_item_count (surface, icon_size, urgent_color, item.Count);
			}
			
			// draw item's progress
			if (item.ProgressVisible)
				theme.draw_item_progress (surface, icon_size, urgent_color, item.Progress);
			
			return surface;
		}

		void draw_green_count_badge (Surface surface, int icon_size, int64 count)
		{
			Color outline_color = { 0.10, 0.26, 0.04, 0.82 };
			Color fill_color = { 0.45, 0.82, 0.08, 1.0 };
			draw_count_badge (surface, icon_size, count, outline_color, fill_color);
		}

		void draw_count_badge (Surface surface, int icon_size, int64 count,
			Color outline_color, Color fill_color)
		{
			unowned Cairo.Context cr = surface.Context;
			var text = count.to_string ();
			var base_radius = double.max (5.0, icon_size * 0.24);
			var font_size = double.max (7.0, icon_size * 0.27);
			Cairo.TextExtents extents;
			cr.select_font_face ("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
			cr.set_font_size (font_size);
			cr.text_extents (text, out extents);
			var radius = double.max (base_radius,
				double.max (extents.width, extents.height) / 2.0 + icon_size * 0.07);
			var x = Math.floor ((surface.Width - icon_size) / 2.0);
			var y = Math.floor ((surface.Height - icon_size) / 2.0);
			var center_x = Gtk.Widget.get_default_direction () == Gtk.TextDirection.RTL
				? x + radius : x + icon_size - radius;
			var center_y = y + radius;

			cr.save ();
			cr.set_source_rgba (outline_color.red, outline_color.green,
				outline_color.blue, outline_color.alpha);
			cr.set_line_width (double.max (1.0, icon_size * 0.035));
			cr.arc (center_x, center_y, radius, 0.0, Math.PI * 2.0);
			cr.stroke_preserve ();
			cr.set_source_rgba (fill_color.red, fill_color.green,
				fill_color.blue, fill_color.alpha);
			cr.fill ();

			cr.set_source_rgba (1.0, 1.0, 1.0, 1.0);
			cr.move_to (center_x - extents.width / 2.0 - extents.x_bearing,
				center_y - extents.height / 2.0 - extents.y_bearing);
			cr.show_text (text);
			cr.restore ();
		}
		
		[CCode (instance_pos = -1)]
		Surface draw_item_background (int width, int height, Surface model, DockItem item)
		{
			unowned PositionManager position_manager = controller.position_manager;
			var shadow_size = position_manager.IconShadowSize * window_scale_factor;
			
			var draw_value = position_manager.get_draw_value_for_item (item);
			var icon_size = (int) draw_value.icon_size * window_scale_factor;
			var icon_surface = item.get_surface (icon_size, icon_size, model);
			
			Logger.verbose ("DockItem.draw_icon_with_shadow (width = %i, height = %i, shadow_size = %i)", width, height, shadow_size);
			var surface = new Surface.with_surface (width, height, model);
			unowned Cairo.Context cr = surface.Context;
			var shadow_surface = icon_surface.create_mask (0.4, null);
			
			var xoffset = 0, yoffset = 0;
			switch (position_manager.Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				yoffset = -shadow_size / 4;
				break;
			case Gtk.PositionType.TOP:
				yoffset = shadow_size / 4;
				break;
			case Gtk.PositionType.LEFT:
				xoffset = shadow_size / 4;
				break;
			case Gtk.PositionType.RIGHT:
				xoffset = -shadow_size / 4;
				break;
			}
			
			cr.set_source_surface (shadow_surface.Internal, shadow_size + xoffset, shadow_size + yoffset);
			cr.paint_with_alpha (0.44);
			surface.gaussian_blur (shadow_size);
			
			return surface;
		}
		
		void draw_indicator_state (Cairo.Context cr, Gdk.Rectangle item_rect, IndicatorState indicator, ItemState item_state)
		{
			unowned PositionManager position_manager = controller.position_manager;
			
			if (indicator_buffer == null) {
				var indicator_color = get_styled_color ();
				indicator_color.set_min_sat (0.4);
				indicator_buffer = theme.create_indicator (position_manager.IndicatorSize, indicator_color, item_buffer);
			}
			if (urgent_indicator_buffer == null) {
				var urgent_indicator_color = get_styled_color ();
				urgent_indicator_color.add_hue (theme.UrgentHueShift);
				urgent_indicator_color.set_sat (1.0);
				urgent_indicator_buffer = theme.create_indicator (position_manager.IndicatorSize, urgent_indicator_color, item_buffer);
			}
			
			unowned Surface indicator_surface = (item_state & ItemState.URGENT) != 0 ? urgent_indicator_buffer : indicator_buffer;
			
			var x = 0.0, y = 0.0;
			switch (position_manager.Position) {
			default:
			case Gtk.PositionType.BOTTOM:
				x = item_rect.x + item_rect.width / 2.0 - indicator_surface.Width / 2.0;
				y = item_buffer.Height - indicator_surface.Height / 2.0 - 2.0 * theme.get_bottom_offset () - indicator_surface.Height / 24.0;
				break;
			case Gtk.PositionType.TOP:
				x = item_rect.x + item_rect.width / 2.0 - indicator_surface.Width / 2.0;
				y = - indicator_surface.Height / 2.0 + 2.0 * theme.get_bottom_offset () + indicator_surface.Height / 24.0;
				break;
			case Gtk.PositionType.LEFT:
				x = - indicator_surface.Width / 2.0 + 2.0 * theme.get_bottom_offset () + indicator_surface.Width / 24.0;
				y = item_rect.y + item_rect.height / 2.0 - indicator_surface.Height / 2.0;
				break;
			case Gtk.PositionType.RIGHT:
				x = item_buffer.Width - indicator_surface.Width / 2.0 - 2.0 * theme.get_bottom_offset () - indicator_surface.Width / 24.0;
				y = item_rect.y + item_rect.height / 2.0 - indicator_surface.Height / 2.0;
				break;
			}
			
			if (indicator == IndicatorState.SINGLE) {
				cr.set_source_surface (indicator_surface.Internal, x, y);
				cr.paint ();
			} else {
				var x_offset = 0.0, y_offset = 0.0;
				if (position_manager.is_horizontal_dock ())
					x_offset = position_manager.IconSize / 16.0;
				else
					y_offset = position_manager.IconSize / 16.0;
				
				cr.set_source_surface (indicator_surface.Internal, x - x_offset, y - y_offset);
				cr.paint ();
				cr.set_source_surface (indicator_surface.Internal, x + x_offset, y + y_offset);
				cr.paint ();
			}
		}
		
		void draw_urgent_glow (DockItem item, Cairo.Context cr, int64 frame_time)
		{
			if ((item.State & ItemState.URGENT) == 0)
				return;
			
			var diff = int64.max (0LL, frame_time - item.LastUrgent);
			if (diff >= theme.GlowTime * 1000)
				return;
			
			unowned PositionManager position_manager = controller.position_manager;
			var x_offset = 0, y_offset = 0;
			
			if (urgent_glow_buffer == null) {
				var urgent_color = get_styled_color ();
				urgent_color.add_hue (theme.UrgentHueShift);
				urgent_color.set_sat (1.0);
				urgent_glow_buffer = theme.create_urgent_glow (position_manager.GlowSize, urgent_color, main_buffer);
			}
			
			position_manager.get_urgent_glow_position (item, out x_offset, out y_offset);
			
			cr.set_source_surface (urgent_glow_buffer.Internal, x_offset, y_offset);
			var opacity = 0.2 + (0.75 * (Math.sin (diff / (double) (theme.GlowPulseTime * 1000) * 2 * Math.PI) + 1) / 2);
			cr.paint_with_alpha (opacity);
		}
		
		Color get_styled_color ()
		{
			unowned Gtk.StyleContext context = theme.get_style_context ();
			var color = (Color) context.get_background_color (context.get_state ());
			color.set_min_val (90 / (double) uint16.MAX);
			return color;
		}
		
		void hidden_changed ()
		{
			force_frame_time_update ();
			var now = frame_time;
			var diff = now - last_hide;
			var time = hide_duration ();
			
			if (diff < time)
				last_hide = now + (diff - time);
			else
				last_hide = now;
			
			if (!screen_is_composited) {
				controller.position_manager.update_dock_position ();
				controller.window.update_size_and_position ();
				return;
			}
			
			controller.window.update_icon_regions ();
			
			animated_draw ();
		}
		
		void hovered_changed ()
		{
			animated_draw ();
		}

		public void update_local_cursor (int x, int y)
		{
			Gdk.Point new_cursor = { x, y };
			if (local_cursor == new_cursor)
				return;
			
			local_cursor = new_cursor;
			
			// The hover zoom follows the pointer
			if (controller.prefs.HoverZoomEnabled && is_application_motion_enabled ())
				animated_draw ();
		}
		
		public void animate_items (Gee.List<DockElement> elements)
		{
			if (!screen_is_composited)
				return;
			
			foreach (var element in elements) {
				DockItem? item = (element as DockItem);
				if (item != null)
					transient_items.add (item);
			}
			
			if (transient_items.size > 0)
				animated_draw ();
		}
		
		/**
		 * {@inheritDoc}
		 */
		protected override bool animation_needed (int64 frame_time)
		{
			if (frame_time - last_hide <= hide_duration ())
				return true;
			
			if (transient_items.size > 0)
				return true;

			next_urgent_repeat = 0LL;
			foreach (var item in current_items)
				if (item_animation_needed (item, frame_time))
					return true;
			
			// Nothing is animating right now, so let the frame clock rest and
			// wake up again when the next repeated attention bounce is due.
			if (next_urgent_repeat > 0LL)
				schedule_urgent_repeat (next_urgent_repeat - frame_time);
			
			return false;
		}

		void schedule_urgent_repeat (int64 delay)
		{
			if (urgent_repeat_timer_id > 0U)
				return;
			
			urgent_repeat_timer_id = Gdk.threads_add_timeout ((uint) (int64.max (0LL, delay) / 1000) + 1, () => {
				urgent_repeat_timer_id = 0U;
				animated_draw ();
				return Source.REMOVE;
			});
		}

		inline bool item_animation_needed (DockItem item, int64 render_time)
		{
			if (item.ClickedAnimation != AnimationType.NONE
				&& render_time - item.LastClicked <= item_click_duration (item))
				return true;
			if (item is ApplicationDockItem && item.HoveredAnimation != AnimationType.NONE
				&& is_application_motion_enabled ()
				&& render_time - item.LastHovered <= item_hover_duration ())
				return true;
			if (item.ScrolledAnimation != AnimationType.NONE
				&& render_time - item.LastScrolled <= ITEM_SCROLL_DURATION * 1000)
				return true;
			if (render_time - item.LastActive <= theme.ActiveTime * 1000)
				return true;
			if (show_notifications) {
				var urgent_elapsed = render_time - item.LastUrgent;
				if (hide_progress == 1.0
					&& urgent_elapsed <= theme.GlowTime * 1000)
					return true;
				if (theme.UrgentBounceTime > 0 && item_urgent_bounce_enabled (item)) {
					var urgent_duration = urgent_bounce_duration ();
					if (urgent_elapsed <= urgent_duration)
						return true;
					if (controller.prefs.UrgentBounceRepeat && (item.State & ItemState.URGENT) != 0) {
						var cycle_duration = urgent_bounce_cycle_duration ();
						var cycle_time = urgent_elapsed % cycle_duration;
						if (cycle_time <= urgent_duration)
							return true;
						// Resting between two bounces, remember when the next one starts
						var next_repeat = render_time + cycle_duration - cycle_time;
						if (next_urgent_repeat == 0LL || next_repeat < next_urgent_repeat)
							next_urgent_repeat = next_repeat;
					}
				}
			}
			if (item.spring_active)
				return true;
			if (item.LastClicked > 0LL && render_time - item.LastClicked <= PRESS_MIN_TIME)
				return true;
			if (render_time - item.LastMove <= item_move_duration ())
				return true;
			if (render_time - item.AddTime <= item_move_duration ())
				return true;
			if (render_time - item.RemoveTime <= item_move_duration ())
				return true;
			if (render_time - item.LastValid <= ITEM_INVALID_DURATION * 1000)
				return true;
			
			return false;
		}

		/**
		 * Whether application icons are allowed to move (zoom and bounce).
		 */
		bool is_application_motion_enabled ()
		{
			return Motion.movement_enabled (controller.prefs);
		}

		/**
		 * The duration of the hide-animation of the dock, in microseconds.
		 */
		int64 hide_duration ()
		{
			return Motion.duration (controller.prefs,
				theme.FadeOpacity == 1.0 ? theme.HideTime : theme.FadeTime);
		}

		/**
		 * The duration of an item moving, being added or removed, in microseconds.
		 */
		int64 item_move_duration ()
		{
			return Motion.duration (controller.prefs, theme.ItemMoveTime);
		}

		/**
		 * The duration of the click-animation of an item, in microseconds.
		 */
		int64 item_click_duration (DockItem item)
		{
			if (item.ClickedAnimation != AnimationType.BOUNCE)
				return theme.ClickTime * 1000LL;
			
			if (!(item is ApplicationDockItem))
				return theme.LaunchBounceTime * 1000LL;
			
			if (!is_application_motion_enabled () || !controller.prefs.LaunchBounceEnabled)
				return 0LL;
			
			return (int64) (theme.LaunchBounceTime * 1000 * application_animation_duration_scale ());
		}

		/**
		 * The duration of the hover-animation of application items, in microseconds.
		 */
		int64 item_hover_duration ()
		{
			return (int64) (ITEM_HOVER_DURATION * 1000 * application_animation_duration_scale ());
		}

		/**
		 * Whether the given item bounces while it is demanding attention.
		 */
		bool item_urgent_bounce_enabled (DockItem item)
		{
			return screen_is_composited && show_notifications
				&& item is ApplicationDockItem
				&& controller.prefs.UrgentBounceEnabled
				&& is_application_motion_enabled ();
		}

		/**
		 * The duration of a single attention bounce, in microseconds.
		 */
		int64 urgent_bounce_duration ()
		{
			return (int64) (theme.UrgentBounceTime * 1000 * application_animation_duration_scale ());
		}

		/**
		 * The duration of an attention bounce and the pause before it repeats, in microseconds.
		 */
		int64 urgent_bounce_cycle_duration ()
		{
			return urgent_bounce_duration () + URGENT_BOUNCE_REPEAT_PAUSE * 1000LL;
		}

		double application_animation_duration_scale ()
		{
			return Motion.duration_scale (controller.prefs);
		}
		
		static int compare_dock_item_position (DockItem i1, DockItem i2)
		{
			var p_i1 = i1.Position;
			var p_i2 = i2.Position;
			
			if (p_i1 > p_i2)
				return 1;
			
			if (p_i1 < p_i2)
				return -1;
			
			if (i1.RemoveTime > i2.RemoveTime)
				return -1;
			
			return 1;
		}
		
		/**
		 * The height [0.0..1.0] of an icon thrown up from the dock, which then
		 * bounces n times in total, each bounce lower and shorter than the last.
		 */
		static double easing_bounce (double t, double d, double n)
			requires (t >= 0.0 && d > 0.0 && n >= 1.0)
			requires (t <= d)
		{
			var p = t / d;
			var count = (int) n;
			
			// A bounce lasts as long as the square root of its height
			var total = 0.0;
			for (var i = 0; i < count; i++)
				total += Math.sqrt (Math.pow (BOUNCE_RESTITUTION, i));
			
			var start = 0.0;
			for (var i = 0; i < count; i++) {
				var height = Math.pow (BOUNCE_RESTITUTION, i);
				var length = Math.sqrt (height) / total;
				if (p < start + length || i == count - 1) {
					var u = ((p - start) / length).clamp (0.0, 1.0);
					return height * 4.0 * u * (1.0 - u);
				}
				start += length;
			}
			
			return 0.0;
		}
		
		static unowned string cairo_surface_type_to_string (Cairo.SurfaceType type)
		{
			unowned string result;
			
			switch (type) {
			case Cairo.SurfaceType.IMAGE: result = "IMAGE"; break;
			case Cairo.SurfaceType.PDF: result = "PDF"; break;
			case Cairo.SurfaceType.PS: result = "PS"; break;
			case Cairo.SurfaceType.XLIB: result = "XLIB"; break;
			case Cairo.SurfaceType.XCB: result = "XCB"; break;
			case Cairo.SurfaceType.GLITZ: result = "GLITZ"; break;
			case Cairo.SurfaceType.QUARTZ: result = "QUARTZ"; break;
			case Cairo.SurfaceType.WIN32: result = "WIN32"; break;
			case Cairo.SurfaceType.BEOS: result = "BEOS"; break;
			case Cairo.SurfaceType.DIRECTFB: result = "DIRECTFB"; break;
			case Cairo.SurfaceType.SVG: result = "SVG"; break;
			case Cairo.SurfaceType.OS2: result = "OS2"; break;
			case Cairo.SurfaceType.WIN32_PRINTING: result = "WIN32_PRINTING"; break;
			case Cairo.SurfaceType.QUARTZ_IMAGE: result = "QUARTZ_IMAGE"; break;
			case Cairo.SurfaceType.SCRIPT: result = "SCRIPT"; break;
			case Cairo.SurfaceType.QT: result = "QT"; break;
			case Cairo.SurfaceType.RECORDING: result = "RECORDING"; break;
			case Cairo.SurfaceType.VG: result = "VG"; break;
			case Cairo.SurfaceType.GL: result = "GL"; break;
			case Cairo.SurfaceType.DRM: result = "DRM"; break;
			case Cairo.SurfaceType.TEE: result = "TEE"; break;
			case Cairo.SurfaceType.XML: result = "XML"; break;
			case Cairo.SurfaceType.SKIA: result = "SKIA"; break;
			case Cairo.SurfaceType.SUBSURFACE: result = "SUBSURFACE"; break;
			//FIXME Available in cairo since 1.12
			//case Cairo.SurfaceType.COGL: result = "COGL"; break;
			default: result = "???"; break;
			}
			
			return result;
		}
	}
}
