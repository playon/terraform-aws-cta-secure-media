import json
import unittest

from cta_client import parse_ttl


class TestTokenLifetime(unittest.TestCase):
    def test_integral_json_numbers_produce_integer_seconds(self):
        for literal, expected in [('3600.0', 3600), ('1e3', 1000), ('7200.0', 7200), ('1.0', 1)]:
            with self.subTest(literal=literal):
                seconds = parse_ttl(json.loads(literal))
                self.assertEqual(seconds, expected)
                self.assertIs(type(seconds), int)

    def test_rejects_non_integral_non_finite_and_out_of_bound_values(self):
        for ttl in [True, False, None, 0, -1, 1.5, 7200.5, 7201, float('inf'), float('-inf'), float('nan')]:
            with self.subTest(ttl=ttl):
                with self.assertRaises(ValueError):
                    parse_ttl(ttl)

    def test_duration_strings_respect_the_same_boundary(self):
        for ttl, expected in [('1s', 1), ('1m', 60), ('1h', 3600), ('120m', 7200), ('2h', 7200)]:
            with self.subTest(ttl=ttl):
                self.assertEqual(parse_ttl(ttl), expected)
        for ttl in ['0s', '7201s', '121m', '3h', '1d', '2h1', '1.5h', '', '2h\n']:
            with self.subTest(ttl=ttl):
                with self.assertRaises(ValueError):
                    parse_ttl(ttl)


if __name__ == '__main__':
    unittest.main()
