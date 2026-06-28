import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
import '../services/storage_service.dart';
import '../services/firebase_messaging_service.dart';
import '../services/fcm_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/app_text_field.dart';
import '../widgets/password_field.dart';
import '../widgets/primary_button.dart';
import 'register_page.dart';
import 'forgot_password_page.dart';
import 'lobby_screen.dart';

/// Sign in screen
class SignInPage extends StatefulWidget {
  static const route = '/sign-in';
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool remember = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadRememberedCredentials();
  }

  Future<void> _loadRememberedCredentials() async {
    final rememberedCredentials =
        await StorageService.getRememberedCredentials();
    if (rememberedCredentials != null && mounted) {
      setState(() {
        _username.text = rememberedCredentials.username;
        _password.text = rememberedCredentials.password;
        remember = true;
      });
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _handleSignIn() async {
    final username = _username.text.trim();
    final password = _password.text;

    if (username.isEmpty || password.isEmpty) {
      _showError('Please enter username and password');
      return;
    }

    setState(() => _isLoading = true);

    try {
      await AuthService.login(username: username, password: password);

      if (remember) {
        await StorageService.saveRememberedCredentials(
          username: username,
          password: password,
        );
      } else {
        await StorageService.clearRememberedCredentials();
      }

      TextInput.finishAutofillContext();

      final fcmToken = FirebaseMessagingService.instance.fcmToken;
      if (fcmToken != null) {
        await FCMService.updateFCMToken(fcmToken);
      }

      if (mounted) {
        Navigator.pushReplacementNamed(context, LobbyScreen.route);
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
    // Pick up vScale from AuthScaffold (desktop/medium) or default to 1.0 (mobile).
    final vScale = AuthVScale.of(context);
    final gap = 16.0 * vScale;
    final smallGap = 8.0 * vScale;

    return AuthScaffold(
      title: 'Sign in',
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextField(
              label: 'Username',
              controller: _username,
              autofillHints: const [AutofillHints.username],
              focusNode: _usernameFocus,
              nextFocusNode: _passwordFocus,
            ),
            SizedBox(height: gap),
            PasswordField(
              label: 'Password',
              controller: _password,
              autofillHints: const [AutofillHints.password],
              focusNode: _passwordFocus,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (!_isLoading) {
                  FocusScope.of(context).unfocus(); // Hide keyboard
                  _handleSignIn();
                }
              },
            ),
            SizedBox(height: smallGap),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () =>
                    Navigator.pushNamed(context, ForgotPasswordPage.route),
                child: const Text(
                  'Forgot password?',
                  style: TextStyle(color: Color(0xFF00E5FF)),
                ),
              ),
            ),
            SizedBox(height: smallGap),
            Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: remember,
                    onChanged: (v) => setState(() => remember = v ?? false),
                    checkColor: Colors.white,
                    activeColor: PrimaryButton.primaryBtn,
                    side: const BorderSide(color: Colors.white70),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => setState(() => remember = !remember),
                  child: const Text(
                    'Remember Me',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
            SizedBox(height: gap),
            PrimaryButton(
              text: _isLoading ? 'Signing in…' : 'Sign In',
              onPressed: _isLoading ? null : _handleSignIn,
            ),
            if (_isLoading)
              Padding(
                padding: EdgeInsets.only(top: smallGap),
                child: const Center(child: CircularProgressIndicator()),
              ),
            SizedBox(height: gap),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  "Don't have an account?",
                  style: TextStyle(color: Colors.white70),
                ),
                TextButton(
                  onPressed: () => Navigator.pushReplacementNamed(
                    context,
                    RegisterPage.route,
                  ),
                  child: const Text(
                    'Create one',
                    style: TextStyle(color: Color(0xFF00E5FF)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
