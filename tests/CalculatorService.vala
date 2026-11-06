//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//

using Plank;

namespace PlankTests
{
	public static void register_calculator_service_tests ()
	{
		Test.add_func ("/Services/CalculatorService/arithmetic", calculator_service_arithmetic);
		Test.add_func ("/Services/CalculatorService/precedence", calculator_service_precedence);
		Test.add_func ("/Services/CalculatorService/invalid", calculator_service_invalid);
	}

	void calculator_service_arithmetic ()
	{
		double result;
		assert (CalculatorService.evaluate ("12 + 3 - 2", out result));
		assert (result == 13.0);
		assert (CalculatorService.evaluate ("7 / 2", out result));
		assert (Math.fabs (result - 3.5) < 0.000001);
		assert (CalculatorService.evaluate ("10 % 4", out result));
		assert (result == 2.0);
		assert (CalculatorService.evaluate ("1,5 * 2", out result));
		assert (result == 3.0);
	}

	void calculator_service_precedence ()
	{
		double result;
		assert (CalculatorService.evaluate ("2 + 3 * (4 - 1)", out result));
		assert (result == 11.0);
		assert (CalculatorService.evaluate ("-(2 + 3) * 2", out result));
		assert (result == -10.0);
	}

	void calculator_service_invalid ()
	{
		double result;
		assert (!CalculatorService.evaluate ("", out result));
		assert (!CalculatorService.evaluate ("1 / 0", out result));
		assert (!CalculatorService.evaluate ("1 +", out result));
		assert (!CalculatorService.evaluate ("(1 + 2", out result));
		assert (!CalculatorService.evaluate ("1.2,3 + 4", out result));
		assert (!CalculatorService.evaluate ("1 + system()", out result));
		assert (!CalculatorService.evaluate ("(((((((((((((((((((((((((((((((((1))))))))))))))))))))))))))))))))) + 1", out result));
	}
}
