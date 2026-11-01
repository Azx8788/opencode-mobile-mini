import 'package:dio/dio.dart';

import 'product_repository.dart' show ProductException;
import 'models.dart' show ApiException;

/// Whether [error] is the server answering "no" (an HTTP reply with a
/// status), as opposed to the request never completing: a dropped
/// connection, a timeout, a server that is down. A refusal is final for an
/// attempt the server tracks; a cut request says nothing about it.
bool errorIsServerAnswer(Object? error) => switch (error) {
  DioException(:final response) => response != null,
  ApiException() => true,
  ProductException(:final cause) => cause != null && errorIsServerAnswer(cause),
  _ => false,
};
