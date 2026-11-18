import unittest
from datetime import timezone

from app.config import parse_datetime


class ConfigTests(unittest.TestCase):
    def test_z_suffix_is_utc(self):
        value = parse_datetime("2024-11-17T00:00:00Z")
        self.assertEqual(value.tzinfo, timezone.utc)
        self.assertEqual(value.isoformat(), "2024-11-17T00:00:00+00:00")

    def test_naive_datetime_is_treated_as_utc(self):
        value = parse_datetime("2024-11-17T00:00:00")
        self.assertEqual(value.tzinfo, timezone.utc)


if __name__ == "__main__":
    unittest.main()
