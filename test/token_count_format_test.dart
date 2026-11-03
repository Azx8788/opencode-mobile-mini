import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/token_count_format.dart';

void main() {
  test('small counts stay exact', () {
    expect(formatTokenCount(0), '0');
    expect(formatTokenCount(-5), '0');
    expect(formatTokenCount(1), '1');
    expect(formatTokenCount(999), '999');
  });

  test('thousands keep one decimal only while it means something', () {
    expect(formatTokenCount(1000), '1k');
    expect(formatTokenCount(1499), '1.5k');
    expect(formatTokenCount(8400), '8.4k');
    expect(formatTokenCount(10000), '10k');
    expect(formatTokenCount(12431), '12k');
    expect(formatTokenCount(999999), '999k');
  });

  test('millions and billions use M and B', () {
    expect(formatTokenCount(1000000), '1M');
    expect(formatTokenCount(1234567), '1.2M');
    expect(formatTokenCount(24000000), '24M');
    expect(formatTokenCount(1000000000), '1B');
  });
}
