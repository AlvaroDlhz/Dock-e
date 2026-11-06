//
// Safe arithmetic expression evaluator for the launcher.
//

namespace Plank
{
	public class CalculatorService : Object
	{
		const int MAX_EXPRESSION_LENGTH = 128;
		const int MAX_NESTING_DEPTH = 32;

		public static bool evaluate (string expression, out double result)
		{
			result = 0.0;
			if (expression.strip () == "" || expression.length > MAX_EXPRESSION_LENGTH)
				return false;

			var parser = new ExpressionParser (expression);
			result = parser.parse ();
			return parser.is_valid () && parser.has_operator () && result.is_finite ();
		}

		class ExpressionParser : Object
		{
			string expression;
			int position = 0;
			int nesting_depth = 0;
			int operator_count = 0;
			bool valid = true;

			public ExpressionParser (string expression)
			{
				this.expression = expression;
			}

			public bool is_valid ()
			{
				skip_whitespace ();
				return valid && position == expression.length;
			}

			public bool has_operator ()
			{
				return operator_count > 0;
			}

			public double parse ()
			{
				var value = parse_expression ();
				skip_whitespace ();
				if (position != expression.length)
					valid = false;
				return value;
			}

			double parse_expression ()
			{
				var value = parse_term ();
				while (valid) {
					skip_whitespace ();
					if (at_end () || (current () != '+' && current () != '-'))
						break;

					var operation = current ();
					position++;
					var right = parse_term ();
					value = operation == '+' ? value + right : value - right;
					operator_count++;
					if (!value.is_finite ())
						valid = false;
				}
				return value;
			}

			double parse_term ()
			{
				var value = parse_factor ();
				while (valid) {
					skip_whitespace ();
					if (at_end () || (current () != '*' && current () != '/'
						&& current () != '%'))
						break;

					var operation = current ();
					position++;
					var right = parse_factor ();
					if ((operation == '/' || operation == '%') && right == 0.0) {
						valid = false;
						break;
					}

					switch (operation) {
					case '*':
						value *= right;
						break;
					case '/':
						value /= right;
						break;
					default:
						value = Math.fmod (value, right);
						break;
					}
					operator_count++;
					if (!value.is_finite ())
						valid = false;
				}
				return value;
			}

			double parse_factor ()
			{
				if (++nesting_depth > MAX_NESTING_DEPTH) {
					valid = false;
					return 0.0;
				}

				skip_whitespace ();
				double value = 0.0;
				if (!at_end () && (current () == '+' || current () == '-')) {
					var negative = current () == '-';
					position++;
					value = parse_factor ();
					if (negative)
						value = -value;
				} else if (!at_end () && current () == '(') {
					position++;
					value = parse_expression ();
					skip_whitespace ();
					if (at_end () || current () != ')')
						valid = false;
					else
						position++;
				} else {
					value = parse_number ();
				}

				nesting_depth--;
				return value;
			}

			double parse_number ()
			{
				var value = 0.0;
				var decimal_place = 0.1;
				var has_digit = false;
				var has_decimal_separator = false;
				while (!at_end ()) {
					var character = current ();
					if (character >= '0' && character <= '9') {
						has_digit = true;
						var digit = character - '0';
						if (has_decimal_separator) {
							value += digit * decimal_place;
							decimal_place *= 0.1;
						} else {
							value = value * 10.0 + digit;
						}
						position++;
						if (!value.is_finite ()) {
							valid = false;
							return 0.0;
						}
					} else if ((character == '.' || character == ',')
						&& !has_decimal_separator) {
						has_decimal_separator = true;
						position++;
					} else {
						break;
					}
				}

				if (!has_digit)
					valid = false;
				return value;
			}

			void skip_whitespace ()
			{
				while (!at_end () && (current () == ' ' || current () == '\t'
					|| current () == '\n' || current () == '\r'))
					position++;
			}

			bool at_end ()
			{
				return position >= expression.length;
			}

			char current ()
			{
				return expression[position];
			}
		}
	}
}
