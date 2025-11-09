import 'package:flutter/material.dart';

void main() {
  runApp(const MessengerApp());
}

class MessengerApp extends StatelessWidget {
  const MessengerApp({super.key});

  static const Color blue900 = Color(0xFF1E3A8A); // rgb(30,58,138)
  static const Color card = Color(0xFF344256); // slate-ish dark card
  static const Color primaryBtn = Color(0xFF2E2A8B); // deep indigo button

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: blue900,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: Colors.transparent,
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFFEFF6FF),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide.none,
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Colors.black),
        bodyMedium: TextStyle(color: Colors.black),
      ),
    );

    return MaterialApp(
      title: 'Flutter Messenger',
      debugShowCheckedModeBanner: false,
      theme: baseTheme,
      home: const SignInPage(),
      routes: {
        SignInPage.route: (_) => const SignInPage(),
        RegisterPage.route: (_) => const RegisterPage(),
        ForgotPasswordPage.route: (_) => const ForgotPasswordPage(),
      },
    );
  }
}

// ---------- Shared auth widgets ----------
class AuthScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  const AuthScaffold({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(
            child: RepaintBoundary(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [MessengerApp.blue900, Color(0xFF172554)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                color: MessengerApp.card,
                elevation: 0,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        const SizedBox(height: 24),
                        child,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AppTextField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  const AppTextField({super.key, required this.label, required this.controller, this.keyboardType});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          decoration: const InputDecoration(),
        ),
      ],
    );
  }
}

class PasswordField extends StatefulWidget {
  final String label;
  final TextEditingController controller;
  const PasswordField({super.key, required this.label, required this.controller});
  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscure = true;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        TextField(
          controller: widget.controller,
          obscureText: _obscure,
          decoration: InputDecoration(
            suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                child: Text(
                  _obscure ? 'reveal' : 'hide',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class PrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  const PrimaryButton({super.key, required this.text, this.onPressed});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: MessengerApp.primaryBtn,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        onPressed: onPressed,
        child: Text(text),
      ),
    );
  }
}

// ---------- Screens ----------
class SignInPage extends StatefulWidget {
  static const route = '/sign-in';
  const SignInPage({super.key});
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool remember = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Sign in',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextField(label: 'Username', controller: _username),
          const SizedBox(height: 18),
          PasswordField(label: 'Password', controller: _password),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pushNamed(context, ForgotPasswordPage.route),
              child: const Text('Forgot password?'),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Checkbox(
                value: remember,
                onChanged: (v) => setState(() => remember = v ?? false),
              ),
              const Text('Remember Me'),
            ],
          ),
          const SizedBox(height: 12),
          PrimaryButton(text: 'Sign In', onPressed: () {}),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Don't have an account? "),
              TextButton(
                onPressed: () => Navigator.pushReplacementNamed(context, RegisterPage.route),
                child: const Text('Create one'),
              ),
            ],
          )
        ],
      ),
    );
  }
}

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
          PrimaryButton(text: 'Register', onPressed: () {}),
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

class ForgotPasswordPage extends StatefulWidget {
  static const route = '/forgot-password';
  const ForgotPasswordPage({super.key});
  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _userOrEmail = TextEditingController();
  @override
  void dispose() {
    _userOrEmail.dispose();
    super.dispose();
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
          PrimaryButton(text: 'Send Reset Link', onPressed: () {}),
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
