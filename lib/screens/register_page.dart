import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/firebase_messaging_service.dart';
import '../services/fcm_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/app_text_field.dart';
import '../widgets/password_field.dart';
import '../widgets/primary_button.dart';
import 'sign_in_page.dart';
import 'home_page.dart';

/// Registration screen
class RegisterPage extends StatefulWidget {
  static const route = '/register';
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    final firstName = _first.text.trim();
    final lastName = _last.text.trim();
    final username = _username.text.trim();
    final email = _email.text.trim();
    final password = _password.text.trim();
    final confirm = _confirm.text.trim();

    // Validation
    if (firstName.isEmpty || username.isEmpty || email.isEmpty || password.isEmpty) {
      _showError('Please fill in all required fields');
      return;
    }

    if (password != confirm) {
      _showError('Passwords do not match');
      return;
    }

    if (password.length < 6) {
      _showError('Password must be at least 6 characters');
      return;
    }

    setState(() => _isLoading = true);

    try {
      await AuthService.register(
        username: username,
        email: email,
        password: password,
        firstName: firstName,
        lastName: lastName.isNotEmpty ? lastName : null,
      );
      
      // Send FCM token to backend after successful registration
      final fcmToken = FirebaseMessagingService.instance.fcmToken;
      if (fcmToken != null) {
        await FCMService.updateFCMToken(fcmToken);
      }
      
      if (mounted) {
        // Navigate to home screen
        Navigator.pushReplacementNamed(context, HomePage.route);
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
      title: 'Create your account',
      child: Column(
        children: [
          AppTextField(label: 'First Name', controller: _first),
          const SizedBox(height: 10),
          AppTextField(label: 'Last Name', controller: _last),
          const SizedBox(height: 10),
          AppTextField(label: 'Username', controller: _username),
          const SizedBox(height: 10),
          AppTextField(label: 'Email', controller: _email, keyboardType: TextInputType.emailAddress),
          const SizedBox(height: 10),
          PasswordField(label: 'Password', controller: _password),
          const SizedBox(height: 10),
          PasswordField(label: 'Confirm Password', controller: _confirm),
          const SizedBox(height: 14),
          PrimaryButton(
            text: 'Register',
            onPressed: _isLoading ? null : _handleRegister,
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(child: CircularProgressIndicator()),
            ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Already have an account? '),
              TextButton(
                onPressed: () => Navigator.pushReplacementNamed(context, SignInPage.route),
                child: const Text('Sign in'),
              )
            ],
          )
        ],
      ),
    );
  }
}
