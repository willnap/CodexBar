import unittest

from patch_claude_swap_spend import codexbar_monthly_spend


class MonthlySpendTests(unittest.TestCase):
    def test_disabled_source_amount_is_preserved_without_an_active_cap(self):
        for minor in (0, 325):
            for cap in (None, {"amount_minor": 20000, "exponent": 2, "currency": "USD"}):
                result = codexbar_monthly_spend({"spend": {
                    "used": {"amount_minor": minor, "exponent": 2, "currency": "USD"},
                    "limit": cap, "enabled": False,
                }})
                self.assertEqual(result["used"], minor / 100)
                self.assertEqual(result["limit"], 0)
                self.assertEqual(result["period"], "Monthly")

    def test_source_exponent_defines_units(self):
        result = codexbar_monthly_spend({"spend": {
            "used": {"amount_minor": 123, "exponent": 0, "currency": "JPY"},
            "limit": {"amount_minor": 1000, "exponent": 0, "currency": "JPY"}, "enabled": True,
        }})
        self.assertEqual(result["used"], 123)
        self.assertEqual(result["pct"], 12.3)

    def test_missing_or_invalid_source_money_cannot_become_zero(self):
        for money in (None, {}, {"amount_minor": -1, "exponent": 2, "currency": "USD"},
                      {"amount_minor": 0, "exponent": 2},
                      {"amount_minor": float("nan"), "exponent": 2, "currency": "USD"}):
            self.assertIsNone(codexbar_monthly_spend({"spend": {"used": money, "enabled": False}}))
        self.assertIsNone(codexbar_monthly_spend({}))

    def test_enabled_incompatible_currency_is_rejected(self):
        self.assertIsNone(codexbar_monthly_spend({"spend": {
            "used": {"amount_minor": 0, "exponent": 2, "currency": "USD"},
            "limit": {"amount_minor": 1000, "exponent": 2, "currency": "EUR"}, "enabled": True,
        }}))


if __name__ == "__main__":
    unittest.main()
