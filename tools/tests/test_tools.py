import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import elm327_sim  # noqa: E402
import pidtool  # noqa: E402


class FormulaTests(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(pidtool.evaluate("(A*256+B)/4", [0x1A, 0xF8]), 1726)
        self.assertEqual(pidtool.evaluate("s16(A,B)/100", [0xFF, 0x38]), -2)
        self.assertEqual(pidtool.evaluate("bit(A,7)", [0x83]), 1)
        self.assertEqual(pidtool.evaluate("-A+1", [3]), -2)

    def test_errors(self):
        for f in ["A+", "foo(A)", "u16(A)"]:
            with self.assertRaises(pidtool.FormulaError):
                pidtool.evaluate(f, [1, 2])
        with self.assertRaises(pidtool.FormulaError):
            pidtool.evaluate("B", [1])

    def test_database(self):
        self.assertEqual(pidtool.validate(), 0)


class SimulatorTests(unittest.TestCase):
    def decode(self, elm, pid_id, header):
        pid = next(p for p in pidtool.load_all() if p["id"] == pid_id)
        elm.handle("ATSH" + header)
        line = elm.handle(pid["service"] + pid["pid"])
        parts = line.split()
        payload = [int(x, 16) for x in parts[2:]]
        return pidtool.evaluate(pid["formula"], pidtool.data_bytes(pid, payload))

    def test_values_decode_with_database_formulas(self):
        elm = elm327_sim.ELM()
        self.assertEqual(self.decode(elm, "OBD.01.63", "7E0"), 470)
        self.assertTrue(700 < self.decode(elm, "OBD.01.0C", "7E0") < 2600)
        self.assertGreater(self.decode(elm, "PCM.22.3037", "7E0"), 5)
        self.assertTrue(-40 < self.decode(elm, "TCM.22.1E1C", "7E1") < 80)

    def test_vin_multiframe(self):
        out = elm327_sim.ELM().handle("0902")
        self.assertEqual(len(out.split("\r")), 3)
        self.assertTrue(out.startswith("7E8 10 14 49 02 01"))

    def test_unknown_did_is_negative(self):
        elm = elm327_sim.ELM()
        elm.handle("ATSH7E0")
        self.assertEqual(elm.handle("22ABCD"), "7E8 03 7F 22 31")


if __name__ == "__main__":
    unittest.main()
