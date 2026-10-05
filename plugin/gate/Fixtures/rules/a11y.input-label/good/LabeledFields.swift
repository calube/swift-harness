import SwiftUI

struct SignInView: View {
  @State private var email = ""
  @State private var password = ""
  @State private var bio = ""
  @State private var query = ""
  @State private var nickname = ""

  var body: some View {
    Form {
      TextField("Email", text: $email)
        .textContentType(.emailAddress)
        .accessibilityIdentifier("signIn.email")
        .accessibilityLabel("Email")
      SecureField("Password", text: $password)
        .accessibilityLabel(Text("Password"))
        .accessibilityIdentifier("signIn.password")
      LabeledContent("Bio") {
        TextEditor(text: $bio)
          .accessibilityIdentifier("signIn.bio")
      }
      TextField("Search", text: $query, prompt: Text("Name or email"))
        .accessibilityIdentifier("signIn.search")
      HStack {
        TextField("Nickname", text: $nickname)
          .accessibilityIdentifier("signIn.nickname")
      }
      .accessibilityLabel("Nickname")
      TextField("Unidentified", text: $nickname)
    }
  }
}
