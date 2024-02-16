print_hash() {
    local count=$1
    for ((i=1; i<=count; i++)); do
        printf "#"
        sleep 0.05
    done
    echo  # Baris baru setelah mencetak karakter #
}
