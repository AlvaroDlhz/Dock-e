//
// Shared animation timing and window transitions.
//

namespace Plank
{
	/**
	 * Timing rules shared by every animation, so they all follow the same preferences.
	 */
	namespace Motion
	{
		/**
		 * The time (in ms) a floating window takes to appear.
		 */
		public const int POPUP_OPEN_TIME = 130;
		/**
		 * The time (in ms) a floating window takes to disappear.
		 */
		public const int POPUP_CLOSE_TIME = 110;
		/**
		 * The time (in ms) a hover label takes to appear.
		 */
		public const int LABEL_OPEN_TIME = 60;
		/**
		 * The size a floating window starts to grow from while appearing.
		 */
		public const double POPUP_SCALE = 0.92;

		/**
		 * Whether anything is allowed to animate at all.
		 */
		public bool animations_enabled ()
		{
			return Gtk.Settings.get_default ().gtk_enable_animations;
		}

		/**
		 * Whether things are allowed to move around (zoom, bounce, slide).
		 * Fades are not affected by this.
		 */
		public bool movement_enabled (DockPreferences prefs)
		{
			return animations_enabled () && !prefs.ReduceMotion;
		}

		/**
		 * The factor applied to every duration for the chosen animation speed.
		 */
		public double duration_scale (DockPreferences prefs)
		{
			switch (prefs.AnimationSpeed) {
			case 0: return 1.5;
			case 2: return 0.65;
			default: return 1.0;
			}
		}

		/**
		 * Converts a duration to microseconds, adjusted to the chosen animation speed.
		 *
		 * @param prefs the preferences of the dock
		 * @param milliseconds the duration at normal speed
		 * @return the duration to use, in microseconds
		 */
		public int64 duration (DockPreferences prefs, int64 milliseconds)
		{
			return (int64) (milliseconds * 1000 * duration_scale (prefs));
		}

		/**
		 * The path of a damped spring released at 0.0 and coming to rest at 1.0.
		 * It covers most of the distance in the first third of the time, passes
		 * its target by a few percent and settles.
		 *
		 * @param p the elapsed part of the animation [0.0..1.0]
		 * @return the position, which may slightly exceed 1.0
		 */
		public double spring_curve (double p)
		{
			if (p <= 0.0)
				return 0.0;
			if (p >= 1.0)
				return 1.0;
			return 1.0 - Math.exp (-6.0 * p) * Math.cos (5.5 * p);
		}

		/**
		 * The progress at which an ease-out-cubic animation reaches the given value.
		 * Used to continue an interrupted animation from where it was.
		 */
		public double ease_out_cubic_inverse (double value)
		{
			return 1.0 - Math.cbrt (1.0 - value.clamp (0.0, 1.0));
		}
	}

	/**
	 * A value pulled towards a moving target by a damped spring. Unlike a timed
	 * curve it keeps its momentum when the target changes half-way.
	 */
	public struct Spring
	{
		public double value;
		public double velocity;

		/**
		 * Advances the spring.
		 *
		 * @param target the value to come to rest at
		 * @param dt the time passed, in seconds
		 * @param response roughly the time (in seconds) taken to reach the target
		 * @param damping 1.0 never passes the target, lower values bounce more
		 * @return whether the spring is still moving
		 */
		public bool step (double target, double dt, double response, double damping)
		{
			var stiffness = Math.pow (2.0 * Math.PI / response, 2.0);
			var friction = 4.0 * Math.PI * damping / response;

			// Small fixed steps keep this stable whatever the frame rate is
			var remaining = dt;
			while (remaining > 0.0) {
				var h = double.min (remaining, 0.004);
				velocity += (stiffness * (target - value) - friction * velocity) * h;
				value += velocity * h;
				remaining -= h;
			}

			if (Math.fabs (target - value) < 0.001 && Math.fabs (velocity) < 0.01) {
				value = target;
				velocity = 0.0;
				return false;
			}

			return true;
		}
	}

	/**
	 * Fades a window in and out in step with the display's frame clock.
	 *
	 * The window may additionally use {@link progress} while drawing,
	 * e.g. to slide its content into place.
	 */
	public class WindowTransition : GLib.Object
	{
		public unowned Gtk.Window window { get; construct; }

		/**
		 * How far the window is shown, from 0.0 (hidden) to 1.0 (fully shown).
		 */
		[CCode (notify = false)]
		public double progress { get; private set; default = 1.0; }

		/**
		 * Emitted when an animation reached its end.
		 *
		 * @param hidden whether the window was hidden by it
		 */
		public signal void finished (bool hidden);

		uint tick_id = 0U;
		ulong hide_handler_id = 0UL;
		double from = 0.0;
		double to = 0.0;
		int64 start_time = 0LL;
		int64 duration = 0LL;
		bool hide_when_done = false;
		bool springy = false;

		public WindowTransition (Gtk.Window window)
		{
			Object (window : window);
		}

		construct
		{
			hide_handler_id = window.hide.connect (stop);
		}

		~WindowTransition ()
		{
			stop ();
			if (hide_handler_id > 0UL)
				window.disconnect (hide_handler_id);
		}

		/**
		 * Stops the running animation, leaving the window as it currently is.
		 */
		public void stop ()
		{
			if (tick_id > 0U) {
				window.remove_tick_callback (tick_id);
				tick_id = 0U;
			}
		}

		/**
		 * Jumps to the given progress without animating.
		 */
		public void jump_to (double target)
		{
			stop ();
			apply (target);
		}

		/**
		 * Animates from the current progress to the given one.
		 *
		 * @param target the progress to reach
		 * @param duration the time to take, in microseconds
		 * @param hide_when_done whether to hide the window at the end
		 * @param springy whether to arrive like a spring instead of slowing down evenly
		 */
		public void animate_to (double target, int64 duration, bool hide_when_done = false,
			bool springy = false)
		{
			stop ();

			if (duration <= 0LL || !Motion.animations_enabled () || !window.visible) {
				apply (target);
				if (hide_when_done && window.visible)
					window.hide ();
				finished (hide_when_done);
				return;
			}

			from = progress;
			to = target;
			this.duration = duration;
			this.hide_when_done = hide_when_done;
			this.springy = springy;
			// Counting starts with the first frame that is actually presented
			start_time = 0LL;
			tick_id = window.add_tick_callback (on_tick);
		}

		bool on_tick (Gtk.Widget widget, Gdk.FrameClock frame_clock)
		{
			var now = frame_clock.get_frame_time ();
			if (start_time == 0LL)
				start_time = now;

			var elapsed = int64.min (duration, now - start_time);
			var eased = springy
				? Motion.spring_curve (elapsed / (double) duration)
				: easing_for_mode (AnimationMode.EASE_OUT_CUBIC, elapsed, duration);
			apply (from + (to - from) * eased);

			if (elapsed < duration)
				return Source.CONTINUE;

			tick_id = 0U;
			if (hide_when_done)
				window.hide ();
			finished (hide_when_done);
			return Source.REMOVE;
		}

		void apply (double value)
		{
			progress = value;
			window.opacity = value.clamp (0.0, 1.0);
			window.queue_draw ();
		}
	}
}
