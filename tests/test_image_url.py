import unittest
from utils import image_url_from_item


class ImageUrlTest(unittest.TestCase):
    def test_reads_trimmed_image_and_thumbnail_fallback(self):
        self.assertEqual("https://example.com/poster.jpg", image_url_from_item({"imageUrl": "  https://example.com/poster.jpg  "}))
        self.assertEqual("https://example.com/thumb.jpg", image_url_from_item({"firstimage": "", "firstimage2": "https://example.com/thumb.jpg"}))

    def test_missing_and_invalid_urls_do_not_become_images(self):
        for value in (None, "", "javascript:alert(1)", "data:image/png;base64,abc", "/poster.jpg", "https://", "https://user:password@example.com/a.jpg", "https://[invalid"):
            with self.subTest(value=value):
                self.assertIsNone(image_url_from_item({"imageUrl": value}))
        self.assertIsNone(image_url_from_item({}))


if __name__ == "__main__":
    unittest.main()
