.intel_syntax noprefix

# Linux Syscall Macros
    .equ SYSCALL_READ, 0
    .equ SYSCALL_WRITE, 1
    .equ SYSCALL_OPEN, 2
    .equ SYSCALL_CLOSE, 3
    .equ SYSCALL_SOCKET, 41
    .equ SYSCALL_ACCEPT, 43
    .equ SYSCALL_BIND, 49
    .equ SYSCALL_LISTEN, 50
    .equ SYSCALL_FORK, 57
    .equ SYSCALL_EXIT, 60
    
# Linux Constant Macros
    .equ SOCKET_STREAM, 1
    .equ AF_INET, 2
    .equ SIZE_SOCKETADDR_IN, 16
    .equ INADDR_ANY, 0
    .equ O_RDONLY, 0
    .equ O_WRONLY, 1
    .equ O_CREAT, 64
    .equ S_IRWXU, 0777

.section .data
    response
    .string HTTP1.0 200 OKrnrn
    .equ response_size, .-response-1

    header_buffer
    .string rnrn

.section .bss
    # Request buffer for reading the HTTP request
    .equ rb_size, 800
    .lcomm request_buffer, rb_size

    # Path buffer for extracting the path from the request
    .equ pb_size, 40
    .lcomm path_buffer, pb_size

    # File buffer for reading the requested file
    .equ fb_size, 400
    .lcomm file_buffer, fb_size

    # Socket file descriptor for listenting and accepted socket
    .lcomm listening_fd, 8
    .lcomm accepted_fd, 8

.section .text

.global _start
_start
setup # Opens a socket and sets it up to listen

    # Socket (rdi AF_INET, rsi SOCKET_STREAM, rdx 0)
    mov rax, SYSCALL_SOCKET
    mov rdi, AF_INET 
    mov rsi, SOCKET_STREAM
    xor rdx, rdx # 0
    syscall # Socket
    # Returns file descriptor in rax

    # Bind (rdi file_descriptor, rsi sockadder_in, rdx sockadder_size)
    mov rdi, rax # File descriptor for created file

    sub rsp, SIZE_SOCKETADDR_IN            # allocate 16 bytes for sockaddr_in
    # Format is 2 bytes socket_type, 2 bytes port_big_endian, 4 bytes address, 8 bytes padding
    mov WORD PTR [rsp], AF_INET
    mov WORD PTR [rsp + 2], 0x5000 # Port 80 (big endian)
    mov DWORD PTR [rsp + 4], INADDR_ANY   # (0.0.0.0)
    mov QWORD PTR [rsp + 8], 0    # Zeros the padding

    mov rsi, rsp # Points to the above structure
    mov rdx, SIZE_SOCKETADDR_IN  # Struct size
    mov rax, SYSCALL_BIND
    syscall # Bind

    # Listen (rdi file_descriptor, rsi backlog)
    # rdi is already set from the last syscall
    xor rsi, rsi # 0 backlog
    mov rax, SYSCALL_LISTEN
    syscall # Listen

    mov [listening_fd], rdi # Save the file descriptor for later

accept_request # Accepts the communication and forks the process.
                #  The parent continues and the child processes the request.

    # Accept(rdi file_descriptor, rsi NULL, rdx NULL)
    mov rdi, [listening_fd] # Recover the file descriptor for loop
    xor rsi, rsi # NULL
    xor rdx, rdx # NULL
    mov rax, SYSCALL_ACCEPT
    syscall # Accept
    # Returns file descriptor in rax

    mov [accepted_fd], rax # Save file descriptor for child process
    mov rdi, rax # Save file descriptor for parent process

    # Fork()
    mov rax, SYSCALL_FORK
    syscall # Fork

    cmp rax, 0 # Checks if parent
    jne close_accept # Parent goes back to accept new request

request_processing # Child continues to process the request.

    mov rdi, [listening_fd] # Get the file descriptor for the listening file

    # Close the listening file
    # Close(rdi file_descriptor)
    mov rax, SYSCALL_CLOSE
    syscall # Close

    # Read(rdi file_descriptor, rsi buffer, rdx read_size)
    mov rdi, [accepted_fd] # Grab file descriptor from stack
    lea rsi, request_buffer # Set pointer to buffer
    mov rax, SYSCALL_READ
    mov rdx, rb_size # Max read size
    syscall # Read

    # Simple parser. The expected read value is POST path other_stuff
    # rnrnPOST_TEXT.
    # This algorithm extracts the path between the first and second
    # space. It takes rsi as the buffer. Returns a buffer in rdi.
    # It also extracts the POST_TEXT and saves it to a buffer in rdx

    parse_start  
        # Look for a space in the request 
        lea rdi, request_buffer
        mov sil, 32
        call search_string

        # Copies the string until a space is found
        mov rdi, rax
        lea rsi, path_buffer
        mov dl, 32
        call copy_string

        # Got the path, now needs to read the text
        # First look for the rnrn
        mov rdi, rax
        lea rsi, header_buffer
        call search_for_string

        # Copy the text
        mov rdi, rax
        lea rsi, file_buffer
        mov rdx, 0
        call copy_string

        # How much was copied
        sub rax, rdi
        push rax
    
    mov al, BYTE PTR [request_buffer]
    cmp rax, 'P'
    je POST
    jmp GET

    POST
        # Create the desired file
        # Open(rdi path, rsi flag, rdx mode)
        lea rdi, path_buffer
        mov rsi, O_WRONLY  O_CREAT
        mov rdx, S_IRWXU # All permissions
        mov rax, SYSCALL_OPEN
        syscall # Open
        # Returns file descriptor in rax

        # Write to the created file
        # Write(rdi file_descriptor, rsi buffer, rdx write_size)
        mov rdi, rax
        lea rsi, file_buffer
        pop rdx
        mov rax, SYSCALL_WRITE
        syscall # Write

        # Close the open file
        # Close(rdi file_descriptor)
        # rdi is already set
        mov rax, SYSCALL_CLOSE
        syscall # Close

        # Send
        # HTTP1.0 200 OKrnrn
        # Write(rdi file_descriptor, rsi buffer, rdx write_size)
        mov rdi, [accepted_fd] # File descriptor
        lea rsi, response # Stored message
        mov rdx, response_size # Fixed size
        mov rax, SYSCALL_WRITE
        syscall # Write
        jmp exit

    GET
        # Open(rdi path, rsi flag, rdx mode)
        lea rdi, path_buffer 
        mov rsi, O_RDONLY
        xor rdx, rdx # 0
        mov rax, SYSCALL_OPEN
        syscall # Open
        # Returns file descriptor in rax

        # Read(rdi file_descriptor, rsi buffer, rdx read_size)
        mov rdi, rax # File descriptor for open file
        lea rsi, file_buffer # Stack buffer
        mov rdx, fb_size # Max read size
        mov rax, SYSCALL_READ
        syscall # Read
        # Returns number of read characters in rax
        push rax

        # Close the open file
        # Close(rdi file_descriptor)
        # rdi is already set
        mov rax, SYSCALL_CLOSE
        syscall # Close

        # Send
        # HTTP1.0 200 OKrnrn
        # Write(rdi file_descriptor, rsi buffer, rdx write_size)
        mov rdi, [accepted_fd] # File descriptor
        lea rsi, response # Stored message
        mov rdx, response_size # Fixed size
        mov rax, SYSCALL_WRITE
        syscall # Write

        # Write again, the read file this time
        # Write(rdi file_descriptor, rsi buffer, rdx write_size)
        # rdi is already set, same as last time
        pop rdx # Saved read size
        lea rsi, file_buffer # Read from file
        mov rax, SYSCALL_WRITE
        syscall # Write

        # Close(rdi file_descriptor)
        # Already set rdi as accepted sockey
        mov rax, SYSCALL_CLOSE
        syscall # Close

    # Zeros out everything to exit
    exit
    mov rax, SYSCALL_EXIT # Exit syscall
    mov rdi, 0
    mov rsi, 0
    mov rdx, 0
    syscall # EXIT

close_accept # The child deals with the request, 
              # so the parent closes the current request.
    # Close(rdi file_descriptor)
    # rdi is already set
    mov rax, SYSCALL_CLOSE
    syscall # Close
    jmp accept_request # Return to accept the next request

# Function that searches for a character in a string
# Input rdi string buffer and rsi stop character
# Output rax string buffer after the character 
.type search_string, @function
search_string
    push rdi
    xor rax, rax

    1 # Loop
    mov al, BYTE PTR [rdi] # Take a character from the buffer
    inc rdi
    cmp al, sil # Look for character
    je 2f # Found the chracter
    jmp 1b

    2 # Done
    mov rax, rdi
    pop rdi
    ret


# Copies the string until a stop character is found
# Input rdi string buffer, rsi copied string buffer,
# rdx stop character.
# Output rax moved input string buffer
.type copy_string, @function
copy_string
    push rdi
    push rsi
    xor rax, rax

    1 # Loop
    mov al, BYTE PTR [rdi] # Takes a character from the buffer
    cmp al, dl # Checks for stop character
    je 2f # Found the character, end
    mov BYTE [rsi-1], al # Saves the character in the output buffer
    inc rsi
    inc rdi
    jmp 1b # Copy the next character

    2
    mov BYTE PTR [rsi], 0  # Add null terminator
    mov rax, rdi # Moved source string
    pop rsi
    pop rdi
    ret

# Function that searches for a target string in a string
# Input rdi string buffer and rsi searched string
# Output rax string buffer after the character 
.type search_for_string, @function
search_for_string
    push rdi
    push rbx
    push rdx
    xor rax, rax
    xor rdx, rdx

    1 # Reset target buffer
    mov rbx, rsi

    2 # Next character
    mov al, BYTE PTR [rdi] # Takes a character from the buffer
    mov dl, BYTE PTR [rbx] # Takes a character from the target buffer
    cmp dl, 0
    je 3f # NULL character found, end
    inc rbx
    inc rdi
    cmp al, dl
    je 2b # Characters match, look for the next character
    jmp 1b # Characters don't match, reset the target string

    3 # Found the string, end
    mov rax, rdi # Moved source string

    pop rdx
    pop rbx
    pop rdi
    ret
