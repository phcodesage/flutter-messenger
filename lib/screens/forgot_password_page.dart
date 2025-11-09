import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/app_text_field.dart';
import '../widgets/primary_button.dart';
import 'sign_in_page.dart';

/// Forgot password screen
class ForgotPasswordPage extends StatefulWidget {
  static const route = '/forgot-password';
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _userOrEmail = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _userOrEmail.dispose();
    super.dispose();
  }

  Future<void> _handleForgotPassword() async {
    final emailOrUsername = _userOrEmail.text.trim();

    if (emailOrUsername.isEmpty) {
      _showError('Please enter your email or username');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final message = await AuthService.forgotPassword(emailOrUsername: emailOrUsername);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.green),
        );
        // Navigate back to sign in after a delay
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            Navigator.pushReplacementNamed(context, SignInPage.route);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        _showError(e.toString().replaceAll('Exception: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Forgot Password',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextField(label: 'Email or Username', controller: _userOrEmail),
          const SizedBox(height: 22),
          PrimaryButton(
            text: 'Send Reset Link',
            onPressed: _isLoading ? null : _handleForgotPassword,
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(child: CircularProgressIndicator()),
            ),
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: () => Navigator.pushReplacementNamed(context, SignInPage.route),
              child: const Text('Back to sign in'),
            ),
          )
        ],
      ),
    );
  }
}
