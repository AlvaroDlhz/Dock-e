/* xdamage.vapi
 *
 * Minimal bindings for the X Damage extension, which reports when the
 * contents of a window change.
 */

[CCode (cheader_filename = "X11/extensions/Xdamage.h")]
namespace XDamage {
	[CCode (cname = "XDamageNotify")]
	public const int NOTIFY;
	[CCode (cname = "XDamageReportNonEmpty")]
	public const int REPORT_NON_EMPTY;

	[CCode (cname = "XDamageQueryExtension")]
	public static bool query_extension (X.Display display, out int event_base, out int error_base);

	[SimpleType]
	[IntegerType (rank = 9)]
	[CCode (cname = "Damage", has_type_id = false)]
	public struct Damage : X.ID {
	}

	[CCode (cname = "XDamageNotifyEvent", has_type_id = false)]
	public struct NotifyEvent {
		public int type;
		public X.Drawable drawable;
		public Damage damage;
	}

	[CCode (cname = "XDamageCreate")]
	public static Damage create (X.Display display, X.Drawable drawable, int level);
	[CCode (cname = "XDamageDestroy")]
	public static void destroy (X.Display display, Damage damage);
	/* Both regions are XserverRegion, zero meaning "all of it" */
	[CCode (cname = "XDamageSubtract")]
	public static void subtract (X.Display display, Damage damage, ulong repair, ulong parts);
}
